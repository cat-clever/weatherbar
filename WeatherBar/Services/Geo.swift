// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation
import CoreLocation

// MARK: - 定位

@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isLocating = false

    private let manager = CLLocationManager()
    private var activeTask: Task<Place, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var authTimeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Place, Error>?
    private var locationTimeoutTask: Task<Void, Never>?
    private var currentRequestID: UInt64 = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .authorizedAlways
    }

    func requestPlace() async throws -> Place {
        if let existing = activeTask {
            return try await existing.value
        }
        let task = Task<Place, Error> { @MainActor [weak self] in
            guard let self else { throw LocationError.unavailable }
            defer { self.activeTask = nil }
            return try await self.performRequestPlace()
        }
        activeTask = task
        return try await task.value
    }

    private func performRequestPlace() async throws -> Place {
        let status = await requestAuthorizationIfNeeded()
        guard status == .authorized || status == .authorizedAlways else {
            throw LocationError.denied
        }

        isLocating = true
        defer { isLocating = false }

        currentRequestID &+= 1
        let reqID = currentRequestID

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.locationTimeoutTask?.cancel()
            self.locationTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.currentRequestID == reqID else { return }
                self.finish(with: .failure(LocationError.timeout))
            }
            self.manager.requestLocation()
        }
    }

    private func requestAuthorizationIfNeeded() async -> CLAuthorizationStatus {
        authorizationStatus = manager.authorizationStatus
        guard authorizationStatus == .notDetermined else { return authorizationStatus }

        manager.requestWhenInUseAuthorization()
        return await withCheckedContinuation { continuation in
            authContinuation = continuation
            authTimeoutTask?.cancel()
            authTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let pending = self.authContinuation else { return }
                self.authContinuation = nil
                let current = self.manager.authorizationStatus
                self.authorizationStatus = current
                pending.resume(returning: current)
            }
        }
    }

    fileprivate func finish(with result: Result<Place, Error>) {
        locationTimeoutTask?.cancel()
        locationTimeoutTask = nil
        guard let pending = continuation else { return }
        continuation = nil
        switch result {
        case .success(let place): pending.resume(returning: place)
        case .failure(let error): pending.resume(throwing: error)
        }
    }
}

enum LocationError: LocalizedError {
    case denied
    case timeout
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied: return "定位权限未开启"
        case .timeout: return "定位超时"
        case .unavailable: return "无法获取位置"
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            if status != .notDetermined, let pending = self.authContinuation {
                self.authContinuation = nil
                self.authTimeoutTask?.cancel()
                self.authTimeoutTask = nil
                pending.resume(returning: status)
            }
            if !self.isAuthorized, status != .notDetermined {
                self.finish(with: .failure(LocationError.denied))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            do {
                let place = try await GeocodingService.shared.reverse(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                self.finish(with: .success(place))
            } catch {
                let fallback = Place(name: "当前位置",
                                     latitude: coordinate.latitude,
                                     longitude: coordinate.longitude,
                                     isCurrentLocation: true)
                self.finish(with: .success(fallback))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(LocationError.unavailable))
        }
    }
}

// MARK: - 地理编码 / 反查

final class GeocodingService: @unchecked Sendable {
    static let shared = GeocodingService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "WeatherBar/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    struct SearchResult: Decodable {
        struct Item: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
            let timezone: String?
        }
        let results: [Item]?
    }

    func search(_ query: String) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }

        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [
            .init(name: "name", value: trimmed),
            .init(name: "count", value: "8"),
            .init(name: "language", value: "zh"),
            .init(name: "format", value: "json")
        ]
        guard let url = comps.url else { return [] }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(SearchResult.self, from: data)
        return (decoded.results ?? []).map { item in
            Place(name: item.name,
                  admin1: item.admin1,
                  country: item.country,
                  latitude: item.latitude,
                  longitude: item.longitude,
                  timezone: item.timezone)
        }
    }

    func reverse(latitude: Double, longitude: Double) async throws -> Place {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_Hans_CN"))
        guard let mark = placemarks.first else { throw LocationError.unavailable }

        // 尽量取到街道/片区级别，而不是只给一个城市名
        let name = mark.subLocality
            ?? mark.thoroughfare
            ?? mark.name
            ?? mark.locality
            ?? "当前位置"
        return Place(name: name,
                     admin1: mark.locality ?? mark.administrativeArea,
                     country: mark.country,
                     latitude: latitude,
                     longitude: longitude,
                     timezone: mark.timeZone?.identifier,
                     isCurrentLocation: true)
    }
}

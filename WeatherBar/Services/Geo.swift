import Foundation
import CoreLocation

// MARK: - 定位

@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isLocating = false

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Place, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .authorizedAlways
    }

    func requestPlace() async throws -> Place {
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            // 等待用户在系统弹窗中做选择
            try? await Task.sleep(nanoseconds: 800_000_000)
            authorizationStatus = manager.authorizationStatus
        }
        guard isAuthorized else { throw LocationError.denied }

        isLocating = true
        defer { isLocating = false }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
            // 15 秒兜底超时
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let pending = self.continuation {
                    self.continuation = nil
                    pending.resume(throwing: LocationError.timeout)
                }
            }
        }
    }

    fileprivate func finish(with result: Result<Place, Error>) {
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
        Task { @MainActor in
            self.authorizationStatus = status
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

        let name = mark.subLocality ?? mark.locality ?? mark.name ?? "当前位置"
        return Place(name: name,
                     admin1: mark.locality ?? mark.administrativeArea,
                     country: mark.country,
                     latitude: latitude,
                     longitude: longitude,
                     timezone: mark.timeZone?.identifier,
                     isCurrentLocation: true)
    }
}

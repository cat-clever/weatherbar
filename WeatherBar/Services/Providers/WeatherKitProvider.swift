// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation
import CryptoKit

// MARK: - Apple WeatherKit（REST + ES256 JWT）

struct WeatherKitCredentials: Codable, Sendable {
    var teamID: String
    var keyID: String
    var serviceID: String
    var privateKeyPEM: String

    var isComplete: Bool {
        !teamID.isEmpty && !keyID.isEmpty && !serviceID.isEmpty && !privateKeyPEM.isEmpty
    }
}

enum JWTError: Error { case invalidKey, signingFailed }

enum ES256JWT {
    static func sign(header: [String: String], payload: [String: Any], pem: String) throws -> String {
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signingInput = "\(base64URL(headerData)).\(base64URL(payloadData))"

        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            throw JWTError.invalidKey
        }
        guard let signature = try? key.signature(for: Data(signingInput.utf8)) else {
            throw JWTError.signingFailed
        }
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class WeatherKitProvider: WeatherProvider {
    let id: ProviderID = .weatherKit
    let requiresAPIKey = true
    let capabilities: ProviderCapabilities = [.hourly, .daily, .alerts, .moonPhase]
    let attribution = ProviderID.weatherKit.attribution

    private let session: URLSession
    private var cachedToken: (token: String, expiresAt: Date)?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "WeatherBar/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    var credentials: WeatherKitCredentials? {
        guard let raw = KeychainStore.shared.string(for: .weatherKitCredentials),
              let data = raw.data(using: .utf8),
              let creds = try? JSONDecoder().decode(WeatherKitCredentials.self, from: data),
              creds.isComplete else { return nil }
        return creds
    }

    func isConfigured() -> Bool { credentials != nil }

    private func token() throws -> String {
        if let cached = cachedToken, cached.expiresAt > Date().addingTimeInterval(60) {
            return cached.token
        }
        guard let creds = credentials else { throw ProviderError.notConfigured(id.displayName) }
        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": creds.teamID,
            "iat": now,
            "exp": now + 3600,
            "sub": creds.serviceID
        ]
        let header = ["alg": "ES256", "kid": creds.keyID, "typ": "JWT"]
        let signed = try ES256JWT.sign(header: header, payload: payload, pem: creds.privateKeyPEM)
        cachedToken = (signed, Date().addingTimeInterval(3600))
        return signed
    }

    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload {
        let bearer = try token()
        let lang = "zh-Hans"
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "weatherkit.apple.com"
        comps.path = "/api/v1/weather/\(lang)/\(place.latitude)/\(place.longitude)"
        comps.queryItems = [
            .init(name: "dataSets", value: "currentWeather,forecastHourly,forecastDaily"),
            .init(name: "timezone", value: place.timezone ?? "Asia/Shanghai")
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.notConfigured("WeatherKit 凭据无效")
        }
        if http.statusCode == 429 { throw ProviderError.quota(id.displayName) }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }

        let raw: WKResponse
        do {
            raw = try JSONDecoder().decode(WKResponse.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
        return Self.makePayload(raw, place: place, hours: hours)
    }

    private static func wallClock(_ iso: String, timezone: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return nil }
        let offset = TimeZone(identifier: timezone)?.secondsFromGMT(for: d) ?? 0
        return d.addingTimeInterval(TimeInterval(offset))
    }

    private static func makePayload(_ raw: WKResponse, place: Place, hours: Int) -> ProviderPayload {
        let tz = place.timezone ?? "Asia/Shanghai"
        let c = raw.currentWeather

        let current = CurrentConditions(
            date: wallClock(c.asOf, timezone: tz) ?? Date(),
            temperature: c.temperature,
            apparentTemperature: c.temperatureApparent ?? c.temperature,
            humidity: Int(((c.humidity ?? 0) * 100).rounded()),
            pressureHPa: c.pressure ?? 1013,
            dewPoint: c.temperatureDewPoint ?? 0,
            visibilityMeters: c.visibility ?? 10_000,
            uvIndex: Double(c.uvIndex ?? 0),
            windSpeed: c.windSpeed ?? 0,
            windDirection: c.windDirection ?? 0,
            windGust: c.windGust ?? 0,
            cloudCover: Int(((c.cloudCover ?? 0) * 100).rounded()),
            precipitation: c.precipitationIntensity ?? 0,
            isDay: c.daylight ?? true,
            code: WeatherCodeMapper.wmo(fromWeatherKit: c.conditionCode)
        )

        var hourPoints: [HourPoint] = []
        for h in (raw.forecastHourly?.hours ?? []).prefix(max(hours, 12)) {
            guard let date = wallClock(h.forecastStart, timezone: tz) else { continue }
            hourPoints.append(HourPoint(
                date: date,
                temperature: h.temperature,
                code: WeatherCodeMapper.wmo(fromWeatherKit: h.conditionCode),
                precipitationChance: Int(((h.precipitationChance ?? 0) * 100).rounded()),
                windSpeed: h.windSpeed ?? 0,
                humidity: Int(((h.humidity ?? 0) * 100).rounded())
            ))
        }

        var dayPoints: [DayPoint] = []
        for d in (raw.forecastDaily?.days ?? []) {
            guard let date = wallClock(d.forecastStart, timezone: tz) else { continue }
            dayPoints.append(DayPoint(
                date: date,
                code: WeatherCodeMapper.wmo(fromWeatherKit: d.conditionCode),
                minTemperature: d.temperatureMin,
                maxTemperature: d.temperatureMax,
                precipitationChance: Int(((d.precipitationChance ?? 0) * 100).rounded()),
                uvIndexMax: Double(d.uvIndexMax ?? 0),
                windMax: d.windSpeedMax ?? 0,
                gustMax: d.windGustMax ?? 0
            ))
        }

        return ProviderPayload(
            providerID: .weatherKit,
            timezone: tz,
            current: current,
            hourly: hourPoints,
            daily: dayPoints,
            alerts: []
        )
    }

    // MARK: 解码结构

    private struct WKResponse: Decodable {
        struct Current: Decodable {
            let asOf: String
            let cloudCover: Double?
            let conditionCode: String
            let daylight: Bool?
            let humidity: Double?
            let precipitationIntensity: Double?
            let pressure: Double?
            let temperature: Double
            let temperatureApparent: Double?
            let temperatureDewPoint: Double?
            let uvIndex: Int?
            let visibility: Double?
            let windDirection: Double?
            let windGust: Double?
            let windSpeed: Double?
        }
        struct Hour: Decodable {
            let forecastStart: String
            let temperature: Double
            let conditionCode: String
            let precipitationChance: Double?
            let windSpeed: Double?
            let humidity: Double?
        }
        struct Day: Decodable {
            let forecastStart: String
            let temperatureMax: Double
            let temperatureMin: Double
            let conditionCode: String
            let precipitationChance: Double?
            let uvIndexMax: Int?
            let windSpeedMax: Double?
            let windGustMax: Double?
        }
        struct Hourly: Decodable { let hours: [Hour] }
        struct Daily: Decodable { let days: [Day] }

        let currentWeather: Current
        let forecastHourly: Hourly?
        let forecastDaily: Daily?
    }
}

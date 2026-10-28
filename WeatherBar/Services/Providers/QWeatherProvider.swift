// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation

// MARK: - 和风天气 QWeather

final class QWeatherProvider: WeatherProvider {
    let id: ProviderID = .qweather
    let requiresAPIKey = true
    let capabilities: ProviderCapabilities = [.hourly, .daily, .alerts]
    let attribution = ProviderID.qweather.attribution

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "WeatherBar/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    func isConfigured() -> Bool {
        !(KeychainStore.shared.string(for: .qweatherKey) ?? "").isEmpty
    }

    private var apiKey: String { KeychainStore.shared.string(for: .qweatherKey) ?? "" }
    private var apiHost: String {
        let host = KeychainStore.shared.string(for: .qweatherHost) ?? ""
        return host.isEmpty ? "devapi.qweather.com" : host
    }

    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload {
        guard isConfigured() else { throw ProviderError.notConfigured(id.displayName) }
        let location = "\(place.longitude),\(place.latitude)"

        async let nowRaw: NowResponse = get("/v7/weather/now", location: location)
        async let hourlyRaw: HourlyResponse = get("/v7/weather/24h", location: location)
        async let dailyRaw: DailyResponse = get("/v7/weather/7d", location: location)

        let now = try await nowRaw
        let hourly = try await hourlyRaw
        let daily = try await dailyRaw

        guard now.code == "200" else { throw ProviderError.http(Int(now.code) ?? -1) }

        let current = CurrentConditions(
            date: Date(),
            temperature: Double(now.now.temp) ?? 0,
            apparentTemperature: Double(now.now.feelsLike) ?? 0,
            humidity: Int(now.now.humidity) ?? 0,
            pressureHPa: Double(now.now.pressure) ?? 1013,
            dewPoint: Double(now.now.dew) ?? 0,
            visibilityMeters: (Double(now.now.vis) ?? 10) * 1000,
            uvIndex: 0,
            windSpeed: Double(now.now.windSpeed) ?? 0,
            windDirection: Double(now.now.wind360) ?? 0,
            windGust: Double(now.now.windSpeed) ?? 0,
            cloudCover: Int(now.now.cloud) ?? 0,
            precipitation: 0,
            isDay: (Int(now.now.icon) ?? 100) < 150,
            code: WeatherCodeMapper.wmo(fromQWeather: now.now.icon)
        )

        let hourPoints: [HourPoint] = hourly.hourly.prefix(max(hours, 12)).compactMap { h -> HourPoint? in
            guard let date = WallClock.date(from: String(h.fxTime.prefix(16))) else { return nil }
            return HourPoint(
                date: date,
                temperature: Double(h.temp) ?? 0,
                code: WeatherCodeMapper.wmo(fromQWeather: h.icon),
                precipitationChance: Int(h.pop) ?? 0,
                windSpeed: Double(h.windSpeed) ?? 0,
                humidity: Int(h.humidity) ?? 0
            )
        }

        let dayPoints: [DayPoint] = daily.daily.compactMap { d -> DayPoint? in
            guard let date = WallClock.date(from: d.fxDate) else { return nil }
            return DayPoint(
                date: date,
                code: WeatherCodeMapper.wmo(fromQWeather: d.iconDay),
                minTemperature: Double(d.tempMin) ?? 0,
                maxTemperature: Double(d.tempMax) ?? 0,
                precipitationChance: 0,
                uvIndexMax: Double(d.uvIndex ?? "") ?? 0,
                windMax: Double(d.windSpeedDay ?? "") ?? 0,
                gustMax: Double(d.windGustDay ?? "") ?? 0
            )
        }

        return ProviderPayload(
            providerID: id,
            timezone: place.timezone ?? "Asia/Shanghai",
            current: current,
            hourly: hourPoints,
            daily: dayPoints,
            alerts: []
        )
    }

    // MARK: 请求

    private func get<T: Decodable>(_ path: String, location: String) async throws -> T {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = apiHost
        comps.path = path
        comps.queryItems = [
            .init(name: "location", value: location),
            .init(name: "lang", value: "zh")
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-QW-Api-Key")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        if http.statusCode == 429 { throw ProviderError.quota(id.displayName) }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    // MARK: 解码结构

    private struct NowResponse: Decodable {
        struct Now: Decodable {
            let temp: String
            let feelsLike: String
            let icon: String
            let text: String
            let wind360: String
            let windSpeed: String
            let humidity: String
            let pressure: String
            let vis: String
            let cloud: String
            let dew: String
        }
        let code: String
        let now: Now
    }

    private struct HourlyResponse: Decodable {
        struct Hour: Decodable {
            let fxTime: String
            let temp: String
            let icon: String
            let text: String
            let pop: String
            let windSpeed: String
            let humidity: String
        }
        let code: String
        let hourly: [Hour]
    }

    private struct DailyResponse: Decodable {
        struct Day: Decodable {
            let fxDate: String
            let sunrise: String?
            let sunset: String?
            let tempMax: String
            let tempMin: String
            let iconDay: String
            let textDay: String
            let uvIndex: String?
            let windSpeedDay: String?
            let windGustDay: String?
        }
        let code: String
        let daily: [Day]
    }
}

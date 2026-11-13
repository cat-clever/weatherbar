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
        let host = Self.sanitizeHost(KeychainStore.shared.string(for: .qweatherHost) ?? "")
        return host.isEmpty ? "devapi.qweather.com" : host
    }

    static func sanitizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        return host
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

        try Self.validateCode(now.code, providerName: id.displayName)
        guard let nowData = now.now else { throw ProviderError.decoding("和风天气实况数据为空") }

        let dailyList = daily.daily ?? []
        let hourlyList = hourly.hourly ?? []

        let tz = TimeZone(identifier: place.timezone ?? "") ?? .current
        let isDay = Self.resolveIsDay(icon: nowData.icon, today: dailyList.first, timeZone: tz)

        let current = CurrentConditions(
            date: Date(),
            temperature: Double(nowData.temp) ?? 0,
            apparentTemperature: Double(nowData.feelsLike ?? nowData.temp) ?? 0,
            humidity: Int(nowData.humidity ?? "0") ?? 0,
            pressureHPa: Double(nowData.pressure ?? "") ?? 1013,
            dewPoint: Double(nowData.dew ?? "") ?? 0,
            visibilityMeters: (Double(nowData.vis ?? "") ?? 10) * 1000,
            uvIndex: 0,
            windSpeed: Double(nowData.windSpeed ?? "") ?? 0,
            windDirection: Double(nowData.wind360 ?? "") ?? 0,
            windGust: Double(nowData.windSpeed ?? "") ?? 0,
            cloudCover: Int(nowData.cloud ?? "") ?? 0,
            precipitation: Double(nowData.precip ?? "") ?? 0,
            isDay: isDay,
            code: WeatherCodeMapper.wmo(fromQWeather: nowData.icon)
        )

        let hourPoints: [HourPoint] = hourlyList.prefix(max(hours, 12)).compactMap { h -> HourPoint? in
            guard let date = WallClock.date(from: String(h.fxTime.prefix(16))) else { return nil }
            return HourPoint(
                date: date,
                temperature: Double(h.temp) ?? 0,
                code: WeatherCodeMapper.wmo(fromQWeather: h.icon),
                precipitationChance: Int(h.pop ?? "") ?? 0,
                windSpeed: Double(h.windSpeed ?? "") ?? 0,
                humidity: Int(h.humidity ?? "") ?? 0,
                pressureHPa: Double(h.pressure ?? ""),
                dewPoint: Double(h.dew ?? ""),
                precipitation: Double(h.precip ?? ""),
                cloudCover: Int(h.cloud ?? "")
            )
        }

        let dayPoints: [DayPoint] = dailyList.compactMap { d -> DayPoint? in
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
            timezone: tz.identifier,
            current: current,
            hourly: hourPoints,
            daily: dayPoints,
            alerts: []
        )
    }

    private static func validateCode(_ code: String, providerName: String) throws {
        guard code != "200" else { return }
        switch code {
        case "401", "403":
            throw ProviderError.notConfigured("\(providerName) API Key 或专属 Host 无效")
        case "402", "429":
            throw ProviderError.quota(providerName)
        default:
            throw ProviderError.http(Int(code) ?? -1)
        }
    }

    /// 150~154 / 350~351 / 456~457 仅表示夜间，100~104 / 300 / 301 / 406 / 407 仅表示白天，其余降水雾雪代码白天黑夜通用
    private static func resolveIsDay(icon: String, today: DailyResponse.Day?, timeZone: TimeZone) -> Bool {
        let nightIcons: Set<String> = ["150", "151", "152", "153", "154", "350", "351", "456", "457"]
        if nightIcons.contains(icon) { return false }
        let dayOnlyIcons: Set<String> = ["100", "101", "102", "103", "104", "300", "301", "406", "407"]
        if dayOnlyIcons.contains(icon) { return true }

        let now = Date()
        let wallNow = now.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: now)))
        let hour = WallClock.hour(of: wallNow)
        let minute = WallClock.calendar.component(.minute, from: wallNow)
        let currentMinutes = hour * 60 + minute

        if let rise = today?.sunrise.flatMap(parseClockMinutes),
           let set = today?.sunset.flatMap(parseClockMinutes) {
            return currentMinutes >= rise && currentMinutes < set
        }
        return hour >= 6 && hour < 18
    }

    private static func parseClockMinutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
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
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.notConfigured("\(id.displayName) API Key 或专属 Host 无效")
        }
        if http.statusCode == 402 || http.statusCode == 429 { throw ProviderError.quota(id.displayName) }
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
            let feelsLike: String?
            let icon: String
            let text: String
            let wind360: String?
            let windSpeed: String?
            let humidity: String?
            let pressure: String?
            let vis: String?
            let cloud: String?
            let dew: String?
            let precip: String?
        }
        let code: String
        let now: Now?
    }

    private struct HourlyResponse: Decodable {
        struct Hour: Decodable {
            let fxTime: String
            let temp: String
            let icon: String
            let text: String
            let pop: String?
            let windSpeed: String?
            let humidity: String?
            let pressure: String?
            let dew: String?
            let cloud: String?
            let precip: String?
        }
        let code: String
        let hourly: [Hour]?
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
        let daily: [Day]?
    }
}

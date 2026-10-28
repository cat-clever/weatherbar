// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation

// MARK: - 微软天气（MSN，非官方）
//
// 接口：https://api.msn.com/weather/overview
// 密钥不是公开申请的，而是 MSN 网页客户端自己用的 weatherAccess。这里在运行时
// 从网页前端 bundle 里自动取，仓库里不存密钥；遇到 401 会清缓存重新取一次。
// 属于实验性数据源：微软随时可能改接口或吊销密钥。

final class MsnWeatherProvider: WeatherProvider {
    let id: ProviderID = .msn
    let requiresAPIKey = false
    let capabilities: ProviderCapabilities = [.hourly, .daily, .alerts]
    let attribution = ProviderID.msn.attribution

    private let session: URLSession
    private var keyCache: String?
    private let keyDefaultsKey = "msn.weatherAccess"

    private static let pageURL = "https://www.msn.com/zh-cn/weather/forecast/in-Shanghai"
    private static let bundlePattern = #"/bundles/v1/weather/latest/SSR-service-entry\.[a-z0-9]+\.js"#
    private static let keyPattern = #"weatherAccess:"([^"]+)""#

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"
        ]
        session = URLSession(configuration: config)
    }

    func isConfigured() -> Bool { true }

    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload {
        var key = try await apiKey()
        var data = try await overviewData(place: place, key: key)

        if data == nil {
            // 密钥失效：清掉缓存重取一次
            keyCache = nil
            UserDefaults.standard.removeObject(forKey: keyDefaultsKey)
            key = try await apiKey()
            data = try await overviewData(place: place, key: key)
        }

        guard let data else { throw ProviderError.http(401) }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            NSLog("WeatherBar MSN decode error: \(error)")
            throw ProviderError.decoding(String(describing: error))
        }

        guard let weather = envelope.value.first?.responses.first?.weather.first else {
            throw ProviderError.decoding("MSN 返回为空")
        }
        return try makePayload(weather, place: place, days: days)
    }

    // MARK: 密钥

    private func apiKey() async throws -> String {
        if let keyCache { return keyCache }
        if let saved = UserDefaults.standard.string(forKey: keyDefaultsKey), !saved.isEmpty {
            keyCache = saved
            return saved
        }

        let html = try await text(Self.pageURL)
        guard let bundlePath = Self.firstMatch(in: html, pattern: Self.bundlePattern) else {
            throw ProviderError.decoding("未找到 MSN 前端 bundle")
        }
        let js = try await text("https://www.msn.com" + bundlePath)
        guard let key = Self.firstMatch(in: js, pattern: Self.keyPattern, group: 1) else {
            throw ProviderError.decoding("未在 bundle 中找到 weatherAccess")
        }

        keyCache = key
        UserDefaults.standard.set(key, forKey: keyDefaultsKey)
        return key
    }

    private func text(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw ProviderError.network("无效 URL") }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func firstMatch(in text: String, pattern: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let r = Range(match.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: 请求

    private func overviewData(place: Place, key: String) async throws -> Data? {
        var comps = URLComponents(string: "https://api.msn.com/weather/overview")!
        comps.queryItems = [
            .init(name: "apikey", value: key),
            .init(name: "ocid", value: "msftweather"),
            .init(name: "cm", value: "zh-cn"),
            .init(name: "locale", value: "zh-cn"),
            .init(name: "units", value: "C"),
            .init(name: "lat", value: String(format: "%.4f", place.latitude)),
            .init(name: "lon", value: String(format: "%.4f", place.longitude))
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        if http.statusCode == 401 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        return data
    }

    // MARK: 解码结构

    private struct Envelope: Decodable {
        struct Item: Decodable {
            struct Response: Decodable { let weather: [Weather] }
            let responses: [Response]
        }
        let value: [Item]
    }

    private struct Weather: Decodable {
        let current: Current?
        let forecast: Forecast?
    }

    private struct Current: Decodable {
        let temp: Double?
        let feels: Double?
        let rh: Double?
        let dewPt: Double?
        let baro: Double?
        let uv: Double?
        let vis: Double?
        let icon: Int?
        let symbol: String?
    }

    private struct Forecast: Decodable {
        let days: [Day]
    }

    private struct Day: Decodable {
        let hourly: [Hour]?
        let daily: Daily?
    }

    private struct Hour: Decodable {
        let valid: String?
        let temp: Double?
        let feels: Double?
        let rh: Double?
        let dewPt: Double?
        let baro: Double?
        let windSpd: Double?
        let windDir: Double?
        let windGust: Double?
        let uv: Double?
        let vis: Double?
        let precip: Double?
        let cloudCover: Double?
        let icon: Int?
    }

    private struct Daily: Decodable {
        let valid: String?
        let tempHi: Double?
        let tempLo: Double?
        let precip: Double?
        let windMax: Double?
        let uv: Double?
        let icon: Int?
    }

    // MARK: 映射

    private func makePayload(_ weather: Weather, place: Place, days: Int) throws -> ProviderPayload {
        let timeZone = TimeZone(identifier: place.timezone ?? "") ?? .current
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        func wall(_ iso: String?) -> Date? {
            guard let iso, let instant = formatter.date(from: iso) else { return nil }
            return instant.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: instant)))
        }

        let rawHours = (weather.forecast?.days ?? []).flatMap { $0.hourly ?? [] }
        var hourly: [HourPoint] = []
        for hour in rawHours {
            guard let date = wall(hour.valid) else { continue }
            hourly.append(HourPoint(
                date: date,
                temperature: hour.temp ?? 0,
                code: Self.code(icon: hour.icon),
                // 逐小时只给降水量（mm），降雨概率按降水量估算
                precipitationChance: (hour.precip ?? 0) > 0 ? min(90, 40 + Int((hour.precip ?? 0) * 20)) : 0,
                windSpeed: hour.windSpd ?? 0,
                humidity: Int((hour.rh ?? 0).rounded()),
                pressureHPa: hour.baro,
                dewPoint: hour.dewPt,
                uvIndex: hour.uv,
                apparentTemperature: hour.feels,
                precipitation: hour.precip,
                cloudCover: hour.cloudCover.map { Int($0.rounded()) }
            ))
        }

        var daily: [DayPoint] = []
        for day in (weather.forecast?.days ?? []).prefix(max(days, 7)) {
            guard let info = day.daily, let date = wall(info.valid) else { continue }
            daily.append(DayPoint(
                date: WallClock.startOfDay(date),
                code: Self.code(icon: info.icon),
                minTemperature: info.tempLo ?? 0,
                maxTemperature: info.tempHi ?? 0,
                precipitationChance: Int((info.precip ?? 0).rounded()),
                uvIndexMax: info.uv ?? 0,
                windMax: info.windMax ?? 0,
                gustMax: info.windMax ?? 0
            ))
        }

        guard !hourly.isEmpty else { throw ProviderError.decoding("MSN 无逐小时数据") }

        let nowWall = wallNow(timeZone: timeZone)
        let currentHour = hourly.min {
            abs($0.date.timeIntervalSince(nowWall)) < abs($1.date.timeIntervalSince(nowWall))
        } ?? hourly[0]

        let current = CurrentConditions(
            date: currentHour.date,
            temperature: weather.current?.temp ?? currentHour.temperature,
            apparentTemperature: weather.current?.feels ?? currentHour.apparentTemperature ?? currentHour.temperature,
            humidity: Int((weather.current?.rh ?? Double(currentHour.humidity)).rounded()),
            pressureHPa: weather.current?.baro ?? currentHour.pressureHPa ?? 1013,
            dewPoint: weather.current?.dewPt ?? currentHour.dewPoint ?? currentHour.temperature,
            visibilityMeters: (weather.current?.vis ?? 20) * 1000,
            uvIndex: weather.current?.uv ?? currentHour.uvIndex ?? 0,
            windSpeed: currentHour.windSpeed,
            windDirection: rawHours.first?.windDir ?? 0,
            windGust: rawHours.first?.windGust ?? currentHour.windSpeed,
            cloudCover: currentHour.cloudCover ?? 0,
            precipitation: currentHour.precipitation ?? 0,
            isDay: weather.current?.symbol?.hasPrefix("d") ?? (WallClock.hour(of: currentHour.date) >= 6 && WallClock.hour(of: currentHour.date) < 18),
            code: Self.code(icon: weather.current?.icon ?? 3)
        )

        return ProviderPayload(
            providerID: .msn,
            timezone: timeZone.identifier,
            current: current,
            hourly: hourly,
            daily: daily,
            alerts: []
        )
    }

    private func wallNow(timeZone: TimeZone) -> Date {
        let now = Date()
        return now.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: now)))
    }

    /// MSN 用的是一套 AccuWeather 风格的图标编号
    private static func code(icon: Int?) -> WeatherCode {
        switch icon ?? 3 {
        case 1, 30, 31, 33: return .clear
        case 2, 5, 34: return .mainlyClear
        case 3, 4, 35, 36, 37: return .partlyCloudy
        case 6, 7, 8, 32, 38: return .overcast
        case 11: return .fog
        case 12, 14, 39: return .rainShowersLight
        case 13, 40: return .rainShowersModerate
        case 15, 16, 17, 41, 42: return .thunderstorm
        case 18: return .rainModerate
        case 19, 20, 21, 43: return .snowLight
        case 22, 23, 44: return .snowModerate
        case 24, 25, 29: return .freezingRainLight
        case 26: return .freezingRainHeavy
        default: return .partlyCloudy
        }
    }
}

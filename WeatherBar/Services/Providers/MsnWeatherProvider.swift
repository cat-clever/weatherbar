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
    private let keyLock = NSLock()
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
            clearCachedKey()
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

        guard let response = envelope.value.first?.responses.first,
              let weather = response.weather.first else {
            throw ProviderError.decoding("MSN 返回为空")
        }
        return try makePayload(weather, source: response.source, place: place, days: days)
    }

    // MARK: 密钥

    private func readCachedKey() -> String? {
        keyLock.lock(); defer { keyLock.unlock() }
        if let keyCache { return keyCache }
        if let saved = UserDefaults.standard.string(forKey: keyDefaultsKey), !saved.isEmpty {
            keyCache = saved
            return saved
        }
        return nil
    }

    private func storeCachedKey(_ key: String) {
        keyLock.lock(); defer { keyLock.unlock() }
        keyCache = key
        UserDefaults.standard.set(key, forKey: keyDefaultsKey)
    }

    private func clearCachedKey() {
        keyLock.lock(); defer { keyLock.unlock() }
        keyCache = nil
        UserDefaults.standard.removeObject(forKey: keyDefaultsKey)
    }

    private func apiKey() async throws -> String {
        if let cached = readCachedKey() {
            return cached
        }

        let html = try await text(Self.pageURL)
        guard let bundlePath = Self.firstMatch(in: html, pattern: Self.bundlePattern) else {
            throw ProviderError.decoding("未找到 MSN 前端 bundle")
        }
        let js = try await text("https://www.msn.com" + bundlePath)
        guard let key = Self.firstMatch(in: js, pattern: Self.keyPattern, group: 1) else {
            throw ProviderError.decoding("未在 bundle 中找到 weatherAccess")
        }

        storeCachedKey(key)
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
            struct Response: Decodable {
                let source: Source?
                let weather: [Weather]
            }
            let responses: [Response]
        }
        let value: [Item]
    }

    private struct Source: Decodable {
        struct Location: Decodable {
            let timezoneName: String?
            enum CodingKeys: String, CodingKey {
                case timezoneName = "TimezoneName"
            }
        }
        let location: Location?
        let utcOffset: String?
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
        let windSpd: Double?
        let windDir: Double?
        let windGust: Double?
        let cloudCover: Double?
        let rainAmount: Double?
        let snowAmount: Double?
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
        let rainAmount: Double?
        let snowAmount: Double?
        let cloudCover: Double?
        let icon: Int?
        let symbol: String?
    }

    private struct Daily: Decodable {
        let valid: String?
        let tempHi: Double?
        let tempLo: Double?
        let precip: Double?
        let windMax: Double?
        let uv: Double?
        let icon: Int?
        let symbol: String?
    }

    // MARK: 映射

    private func makePayload(_ weather: Weather, source: Source?, place: Place, days: Int) throws -> ProviderPayload {
        let timeZone = Self.resolveTimeZone(place: place, source: source)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        func wall(_ iso: String?) -> Date? {
            guard let iso, let instant = formatter.date(from: iso) else { return nil }
            return instant.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: instant)))
        }

        let rawHours = (weather.forecast?.days ?? []).flatMap { $0.hourly ?? [] }
        var matchedPairs: [(raw: Hour, point: HourPoint)] = []
        for hour in rawHours {
            guard let date = wall(hour.valid) else { continue }
            // MSN 的 precip 字段单位是 %（降水概率），实际降水量在 rainAmount / snowAmount（mm）
            let chance = min(100, max(0, Int((hour.precip ?? 0).rounded())))
            let precipAmount: Double? = (hour.rainAmount != nil || hour.snowAmount != nil)
                ? (hour.rainAmount ?? 0) + (hour.snowAmount ?? 0)
                : nil
            let point = HourPoint(
                date: date,
                temperature: hour.temp ?? 0,
                code: Self.code(symbol: hour.symbol, icon: hour.icon),
                precipitationChance: chance,
                windSpeed: hour.windSpd ?? 0,
                humidity: Int((hour.rh ?? 0).rounded()),
                pressureHPa: hour.baro,
                dewPoint: hour.dewPt,
                uvIndex: hour.uv,
                apparentTemperature: hour.feels,
                precipitation: precipAmount,
                cloudCover: hour.cloudCover.map { Int($0.rounded()) }
            )
            matchedPairs.append((hour, point))
        }

        let hourly = matchedPairs.map(\.point)

        var daily: [DayPoint] = []
        for day in (weather.forecast?.days ?? []).prefix(max(days, 7)) {
            guard let info = day.daily, let date = wall(info.valid) else { continue }
            daily.append(DayPoint(
                date: WallClock.startOfDay(date),
                code: Self.code(symbol: info.symbol, icon: info.icon),
                minTemperature: info.tempLo ?? 0,
                maxTemperature: info.tempHi ?? 0,
                precipitationChance: min(100, max(0, Int((info.precip ?? 0).rounded()))),
                uvIndexMax: info.uv ?? 0,
                windMax: info.windMax ?? 0,
                gustMax: info.windMax ?? 0
            ))
        }

        guard !matchedPairs.isEmpty else { throw ProviderError.decoding("MSN 无逐小时数据") }

        let nowWall = wallNow(timeZone: timeZone)
        let closest = matchedPairs.min {
            abs($0.point.date.timeIntervalSince(nowWall)) < abs($1.point.date.timeIntervalSince(nowWall))
        } ?? matchedPairs[0]
        let currentHour = closest.point
        let matchedRaw = closest.raw

        let currentPrecip: Double = {
            if weather.current?.rainAmount != nil || weather.current?.snowAmount != nil {
                return (weather.current?.rainAmount ?? 0) + (weather.current?.snowAmount ?? 0)
            }
            return currentHour.precipitation ?? 0
        }()

        let current = CurrentConditions(
            date: currentHour.date,
            temperature: weather.current?.temp ?? currentHour.temperature,
            apparentTemperature: weather.current?.feels ?? currentHour.apparentTemperature ?? currentHour.temperature,
            humidity: Int((weather.current?.rh ?? Double(currentHour.humidity)).rounded()),
            pressureHPa: weather.current?.baro ?? currentHour.pressureHPa ?? 1013,
            dewPoint: weather.current?.dewPt ?? currentHour.dewPoint ?? currentHour.temperature,
            visibilityMeters: (weather.current?.vis ?? 20) * 1000,
            uvIndex: weather.current?.uv ?? currentHour.uvIndex ?? 0,
            windSpeed: weather.current?.windSpd ?? currentHour.windSpeed,
            windDirection: weather.current?.windDir ?? matchedRaw.windDir ?? 0,
            windGust: weather.current?.windGust ?? matchedRaw.windGust ?? currentHour.windSpeed,
            cloudCover: weather.current?.cloudCover.map { Int($0.rounded()) } ?? currentHour.cloudCover ?? 0,
            precipitation: currentPrecip,
            isDay: Self.isDay(symbol: weather.current?.symbol, date: currentHour.date),
            code: Self.code(symbol: weather.current?.symbol, icon: weather.current?.icon)
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

    private static func resolveTimeZone(place: Place, source: Source?) -> TimeZone {
        if let id = place.timezone, !id.isEmpty, let tz = TimeZone(identifier: id) {
            return tz
        }
        if let name = source?.location?.timezoneName, !name.isEmpty, let tz = TimeZone(identifier: name) {
            return tz
        }
        if let offsetStr = source?.utcOffset, let seconds = parseUTCOffsetSeconds(offsetStr),
           let tz = TimeZone(secondsFromGMT: seconds) {
            return tz
        }
        return .current
    }

    private static func parseUTCOffsetSeconds(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sign = trimmed.hasPrefix("-") ? -1 : 1
        let unsigned = (trimmed.hasPrefix("-") || trimmed.hasPrefix("+")) ? String(trimmed.dropFirst()) : trimmed
        let parts = unsigned.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        let hours = parts[0]
        let minutes = parts.count > 1 ? parts[1] : 0
        let seconds = parts.count > 2 ? parts[2] : 0
        return sign * (hours * 3600 + minutes * 60 + seconds)
    }

    private func wallNow(timeZone: TimeZone) -> Date {
        let now = Date()
        return now.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: now)))
    }

    static func isDay(symbol: String?, date: Date) -> Bool {
        if let first = symbol?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().first {
            if first == "d" { return true }
            if first == "n" { return false }
        }
        let hour = WallClock.hour(of: date)
        return hour >= 6 && hour < 18
    }

    /// 优先使用 Foreca 4~5 位 `symbol`（如 d410/n310），缺失或未知时回退到 MSN 数字 `icon`
    static func code(symbol: String?, icon: Int?) -> WeatherCode {
        if let symbol, let mapped = code(fromSymbol: symbol) {
            return mapped
        }
        return code(icon: icon)
    }

    static func code(fromSymbol raw: String) -> WeatherCode? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count >= 4, let first = s.first, first == "d" || first == "n" else {
            return nil
        }
        let start = s.index(after: s.startIndex)
        let end = s.index(start, offsetBy: 3)
        let key = String(s[start..<end])
        switch key {
        case "000": return .clear
        case "100": return .mainlyClear
        case "200", "300", "500": return .partlyCloudy
        case "400": return .overcast
        case "600", "900", "907": return .fog
        case "603": return .freezingRainLight
        case "605": return .freezingRainHeavy
        case "705", "905": return .thunderstormHail

        case "010", "110", "210", "310", "020", "120", "220": return .rainShowersLight
        case "320": return .rainShowersModerate
        case "030", "130", "410": return .rainLight
        case "230", "330", "420": return .rainModerate
        case "430": return .rainHeavy

        case "011", "111", "211", "311", "411",
             "021", "121", "221", "321", "421",
             "031", "131", "231", "331", "431":
            return .freezingRainLight

        case "012", "112", "212", "312": return .snowShowersLight
        case "022", "122", "222", "322": return .snowShowersHeavy
        case "032", "132", "412": return .snowLight
        case "232", "332", "422": return .snowModerate
        case "432": return .snowHeavy

        case "040", "140", "240", "340", "440": return .thunderstorm
        case "041", "141", "241", "341", "441",
             "042", "142", "242", "342", "442":
            return .thunderstormHail

        default: return nil
        }
    }

    /// MSN 内部 skyCode 图标编号兜底表（非 AccuWeather 编号）
    static func code(icon: Int?) -> WeatherCode {
        switch icon ?? 3 {
        case 1, 28, 101, 102: return .clear
        case 2, 29: return .mainlyClear
        case 3, 4, 30, 31, 39: return .partlyCloudy
        case 5, 32, 59, 91, 92: return .overcast
        case 9, 12, 18, 21, 36, 45, 48, 54, 55, 57, 58, 63, 64, 89, 90: return .fog
        case 8, 19, 35, 46: return .rainLight
        case 17, 44: return .rainShowersLight
        case 50, 79, 80: return .rainShowersModerate
        case 13, 23, 40: return .rainModerate
        case 14, 22, 41, 49: return .rainHeavy
        case 10, 11, 37, 38, 69, 70, 71, 72,
             24, 51, 75, 76, 77, 78, 83, 84, 85, 86:
            return .freezingRainLight
        case 16, 43: return .freezingRainHeavy
        case 20, 47: return .snowLight
        case 26, 81, 82: return .snowShowersLight
        case 7, 25, 34, 52, 53, 60: return .snowModerate
        case 15, 42: return .snowHeavy
        case 27, 56, 67, 68: return .thunderstorm
        case 6, 33, 61, 62, 65, 66, 73, 74, 87, 88, 93, 94, 95, 96:
            return .thunderstormHail
        default: return .partlyCloudy
        }
    }
}

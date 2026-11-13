// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation

// MARK: - 心知天气 Seniverse

final class SeniverseProvider: WeatherProvider {
    let id: ProviderID = .seniverse
    let requiresAPIKey = true
    let capabilities: ProviderCapabilities = [.hourly, .daily]
    let attribution = ProviderID.seniverse.attribution

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "WeatherBar/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    private var apiKey: String { KeychainStore.shared.string(for: .seniverseKey) ?? "" }

    func isConfigured() -> Bool { !apiKey.isEmpty }

    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload {
        guard isConfigured() else { throw ProviderError.notConfigured(id.displayName) }
        let location = "\(place.latitude):\(place.longitude)"

        async let nowResp: SeniverseEnvelope<NowResult> = get("now.json", location: location, extra: [:])
        async let dailyResp: SeniverseEnvelope<DailyResult> = get("daily.json", location: location, extra: ["days": "7"])
        // 心知免费版无 hourly.json 权限（返回 403 / AP010012），降级为仅返回实况+逐日
        async let hourlyResp: SeniverseEnvelope<HourlyResult>? = fetchOptionalHourly(location: location)

        let now = try await nowResp
        let daily = try await dailyResp
        let hourly = await hourlyResp

        guard let nowResult = now.results.first else { throw ProviderError.decoding("empty results") }
        let today = daily.results.first?.daily.first
        let tzIdentifier = nowResult.location.timezone ?? place.timezone ?? "Asia/Shanghai"
        let tz = TimeZone(identifier: tzIdentifier) ?? .current
        let nowInstant = Date()
        let wallNow = nowInstant.addingTimeInterval(TimeInterval(tz.secondsFromGMT(for: nowInstant)))
        let localHour = WallClock.hour(of: wallNow)

        let current = CurrentConditions(
            date: Date(),
            temperature: Double(nowResult.now.temperature) ?? 0,
            apparentTemperature: Double(nowResult.now.temperature) ?? 0,
            humidity: Int(today?.humidity ?? "0") ?? 0,
            pressureHPa: 1013,
            dewPoint: 0,
            visibilityMeters: 10_000,
            uvIndex: 0,
            windSpeed: Double(today?.windSpeed ?? "0") ?? 0,
            windDirection: 0,
            windGust: 0,
            cloudCover: 0,
            precipitation: 0,
            isDay: localHour >= 6 && localHour < 18,
            code: WeatherCodeMapper.wmo(fromSeniverse: nowResult.now.code)
        )

        let hourPoints: [HourPoint] = (hourly?.results.first?.hourly ?? []).prefix(max(hours, 12)).compactMap { h -> HourPoint? in
            guard let date = WallClock.date(from: String(h.time.prefix(16))) else { return nil }
            return HourPoint(
                date: date,
                temperature: Double(h.temperature) ?? 0,
                code: WeatherCodeMapper.wmo(fromSeniverse: h.code),
                precipitationChance: 0,
                windSpeed: Double(h.windSpeed ?? "0") ?? 0,
                humidity: Int(h.humidity ?? "0") ?? 0
            )
        }

        let dayPoints: [DayPoint] = (daily.results.first?.daily ?? []).compactMap { d -> DayPoint? in
            guard let date = WallClock.date(from: d.date) else { return nil }
            return DayPoint(
                date: date,
                code: WeatherCodeMapper.wmo(fromSeniverse: d.codeDay),
                minTemperature: Double(d.low) ?? 0,
                maxTemperature: Double(d.high) ?? 0,
                precipitationChance: 0,
                uvIndexMax: 0,
                windMax: Double(d.windSpeed ?? "0") ?? 0,
                gustMax: 0
            )
        }

        return ProviderPayload(
            providerID: id,
            timezone: tzIdentifier,
            current: current,
            hourly: hourPoints,
            daily: dayPoints,
            alerts: []
        )
    }

    private func fetchOptionalHourly(location: String) async -> SeniverseEnvelope<HourlyResult>? {
        do {
            let resp: SeniverseEnvelope<HourlyResult> = try await get("hourly.json", location: location, extra: ["hours": "24"])
            return resp
        } catch {
            return nil
        }
    }

    private func get<T: Decodable>(_ path: String,
                                   location: String,
                                   extra: [String: String]) async throws -> T {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.seniverse.com"
        comps.path = "/v3/weather/" + path
        var items: [URLQueryItem] = [
            .init(name: "key", value: apiKey),
            .init(name: "location", value: location),
            .init(name: "language", value: "zh-Hans"),
            .init(name: "unit", value: "c")
        ]
        items.append(contentsOf: extra.map { URLQueryItem(name: $0.key, value: $0.value) })
        comps.queryItems = items
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        if !(200..<300).contains(http.statusCode) {
            if let err = try? JSONDecoder().decode(SeniverseErrorResponse.self, from: data) {
                switch err.statusCode {
                case "AP010001", "AP010002", "AP010003", "AP010010":
                    throw ProviderError.notConfigured("\(id.displayName) API Key 无效")
                case "AP010012":
                    throw ProviderError.unsupported("当前套餐不支持 \(path)")
                case "AP010013", "AP010014":
                    throw ProviderError.quota(id.displayName)
                default:
                    break
                }
            }
            if http.statusCode == 401 { throw ProviderError.notConfigured("\(id.displayName) API Key 无效") }
            if http.statusCode == 403 || http.statusCode == 429 { throw ProviderError.quota(id.displayName) }
            throw ProviderError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }
}

// MARK: - 解码结构

private struct SeniverseErrorResponse: Decodable {
    let status: String?
    let statusCode: String?
    enum CodingKeys: String, CodingKey {
        case status
        case statusCode = "status_code"
    }
}

struct SeniverseEnvelope<T: Decodable>: Decodable {
    let results: [T]
}

struct SeniverseLocation: Decodable {
    let name: String?
    let timezone: String?
}

struct NowResult: Decodable {
    struct Now: Decodable {
        let text: String
        let code: String
        let temperature: String
    }
    let location: SeniverseLocation
    let now: Now
}

struct HourlyResult: Decodable {
    struct Hour: Decodable {
        let time: String
        let text: String
        let code: String
        let temperature: String
        let humidity: String?
        let windSpeed: String?

        enum CodingKeys: String, CodingKey {
            case time, text, code, temperature, humidity
            case windSpeed = "wind_speed"
        }
    }
    let location: SeniverseLocation
    let hourly: [Hour]
}

struct DailyResult: Decodable {
    struct Day: Decodable {
        let date: String
        let textDay: String
        let codeDay: String
        let high: String
        let low: String
        let humidity: String?
        let windSpeed: String?

        enum CodingKeys: String, CodingKey {
            case date, high, low, humidity
            case textDay = "text_day"
            case codeDay = "code_day"
            case windSpeed = "wind_speed"
        }
    }
    let location: SeniverseLocation
    let daily: [Day]
}

// MARK: - 高德天气 AMap

final class AMapProvider: WeatherProvider {
    let id: ProviderID = .amap
    let requiresAPIKey = true
    let capabilities: ProviderCapabilities = [.daily]
    let attribution = ProviderID.amap.attribution

    private let session: URLSession
    private let cacheLock = NSLock()
    private var adcodeCache: [String: String] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "WeatherBar/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    private var apiKey: String { KeychainStore.shared.string(for: .amapKey) ?? "" }

    func isConfigured() -> Bool { !apiKey.isEmpty }

    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload {
        guard isConfigured() else { throw ProviderError.notConfigured(id.displayName) }
        let adcode = try await adcode(for: place)

        async let forecastReq: AMapWeatherResponse = fetchWeatherInfo(adcode: adcode, extensions: "all")
        async let liveReq: AMapLiveResponse? = try? await fetchWeatherInfo(adcode: adcode, extensions: "base")

        let raw = try await forecastReq
        let liveResp = await liveReq

        guard raw.status == "1" else {
            throw Self.mapAMapError(info: raw.info, infocode: raw.infocode)
        }
        guard let forecast = raw.forecasts?.first else {
            throw ProviderError.decoding(raw.info ?? "AMap 返回异常")
        }

        let casts = forecast.casts
        let today = casts.first
        let live = (liveResp?.status == "1") ? liveResp?.lives?.first : nil

        let tz = TimeZone(identifier: place.timezone ?? "Asia/Shanghai") ?? .current
        let nowInstant = Date()
        let wallNow = nowInstant.addingTimeInterval(TimeInterval(tz.secondsFromGMT(for: nowInstant)))
        let localHour = WallClock.hour(of: wallNow)

        let tempValue = Double(live?.temperature ?? today?.daytemp ?? "0") ?? 0
        let currentCode = WeatherCodeMapper.wmo(fromAMap: live?.weather ?? today?.dayweather ?? "")
        let currentWind = Self.windSpeedKmh(fromAMapPower: live?.windpower)

        let current = CurrentConditions(
            date: Date(),
            temperature: tempValue,
            apparentTemperature: tempValue,
            humidity: Int(live?.humidity ?? "0") ?? 0,
            pressureHPa: 1013,
            dewPoint: 0,
            visibilityMeters: 10_000,
            uvIndex: 0,
            windSpeed: currentWind,
            windDirection: 0,
            windGust: currentWind,
            cloudCover: 0,
            precipitation: 0,
            isDay: localHour >= 6 && localHour < 18,
            code: currentCode
        )

        let dayPoints: [DayPoint] = casts.compactMap { c -> DayPoint? in
            guard let date = WallClock.date(from: c.date) else { return nil }
            let dayWind = Self.windSpeedKmh(fromAMapPower: c.daypower)
            return DayPoint(
                date: date,
                code: WeatherCodeMapper.wmo(fromAMap: c.dayweather),
                minTemperature: Double(c.nighttemp) ?? 0,
                maxTemperature: Double(c.daytemp) ?? 0,
                precipitationChance: 0,
                uvIndexMax: 0,
                windMax: dayWind,
                gustMax: dayWind
            )
        }

        return ProviderPayload(
            providerID: id,
            timezone: tz.identifier,
            current: current,
            hourly: [],
            daily: dayPoints,
            alerts: []
        )
    }

    private func fetchWeatherInfo<T: Decodable>(adcode: String, extensions: String) async throws -> T {
        var comps = URLComponents(string: "https://restapi.amap.com/v3/weather/weatherInfo")!
        comps.queryItems = [
            .init(name: "key", value: apiKey),
            .init(name: "city", value: adcode),
            .init(name: "extensions", value: extensions)
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }

    private func cachedAdcode(for key: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return adcodeCache[key]
    }

    private func storeAdcode(_ code: String, for key: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        adcodeCache[key] = code
    }

    private func adcode(for place: Place) async throws -> String {
        let key = String(format: "%.2f,%.2f", place.latitude, place.longitude)
        if let cached = cachedAdcode(for: key) {
            return cached
        }

        var comps = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo")!
        comps.queryItems = [
            .init(name: "key", value: apiKey),
            .init(name: "location", value: "\(place.longitude),\(place.latitude)")
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }

        let raw = try JSONDecoder().decode(AMapRegeoResponse.self, from: data)
        if raw.status != "1" {
            throw Self.mapAMapError(info: raw.info, infocode: raw.infocode)
        }
        guard let code = raw.regeocode?.addressComponent?.adcode, !code.isEmpty else {
            throw ProviderError.unsupported("当前地区不在高德覆盖范围")
        }
        storeAdcode(code, for: key)
        return code
    }

    private static func mapAMapError(info: String?, infocode: String?) -> ProviderError {
        switch infocode {
        case "10001", "10009", "10012":
            return .notConfigured("高德天气 Key 无效")
        case "10003", "10004", "10019", "10020", "10021":
            return .quota("高德天气")
        default:
            return .decoding(info ?? "AMap 返回异常")
        }
    }

    /// 高德 windpower 如 "≤3"、"3"、"4-5" → 粗略换算为 km/h
    private static func windSpeedKmh(fromAMapPower raw: String?) -> Double {
        guard let raw else { return 0 }
        let digits = raw.filter(\.isNumber)
        guard let level = Double(digits.prefix(1)) else { return 0 }
        switch Int(level) {
        case 0: return 1
        case 1: return 4
        case 2: return 9
        case 3: return 15
        case 4: return 24
        case 5: return 34
        case 6: return 44
        case 7: return 56
        case 8: return 68
        default: return 80
        }
    }
}

struct AMapRegeoResponse: Decodable {
    struct Regeocode: Decodable {
        struct AddressComponent: Decodable {
            let adcode: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // 高德在海外坐标会把 adcode 返回成 [] 空数组而非字符串
                adcode = try? c.decodeIfPresent(String.self, forKey: .adcode)
            }

            enum CodingKeys: String, CodingKey { case adcode }
        }
        let addressComponent: AddressComponent?
    }
    let status: String
    let info: String?
    let infocode: String?
    let regeocode: Regeocode?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(String.self, forKey: .status)) ?? "0"
        info = try? c.decodeIfPresent(String.self, forKey: .info)
        infocode = try? c.decodeIfPresent(String.self, forKey: .infocode)
        regeocode = try? c.decodeIfPresent(Regeocode.self, forKey: .regeocode)
    }

    enum CodingKeys: String, CodingKey { case status, info, infocode, regeocode }
}

struct AMapLiveResponse: Decodable {
    struct Live: Decodable {
        let weather: String?
        let temperature: String?
        let humidity: String?
        let windpower: String?
    }
    let status: String
    let info: String?
    let infocode: String?
    let lives: [Live]?
}

struct AMapWeatherResponse: Decodable {
    struct Forecast: Decodable {
        struct Cast: Decodable {
            let date: String
            let dayweather: String
            let nightweather: String
            let daytemp: String
            let nighttemp: String
            let daywind: String?
            let daypower: String?
        }
        let casts: [Cast]
    }
    let status: String
    let info: String?
    let infocode: String?
    let forecasts: [Forecast]?
}

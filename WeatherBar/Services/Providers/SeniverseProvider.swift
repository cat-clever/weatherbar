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
        async let hourlyResp: SeniverseEnvelope<HourlyResult> = get("hourly.json", location: location, extra: ["hours": "24"])
        async let dailyResp: SeniverseEnvelope<DailyResult> = get("daily.json", location: location, extra: ["days": "7"])

        let now = try await nowResp
        let hourly = try await hourlyResp
        let daily = try await dailyResp

        guard let nowResult = now.results.first else { throw ProviderError.decoding("empty results") }
        let today = daily.results.first?.daily.first

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
            isDay: Calendar.current.component(.hour, from: Date()) >= 6
                && Calendar.current.component(.hour, from: Date()) < 18,
            code: WeatherCodeMapper.wmo(fromSeniverse: nowResult.now.code)
        )

        let hourPoints: [HourPoint] = (hourly.results.first?.hourly ?? []).prefix(max(hours, 12)).compactMap { h -> HourPoint? in
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
            timezone: nowResult.location.timezone ?? place.timezone ?? "Asia/Shanghai",
            current: current,
            hourly: hourPoints,
            daily: dayPoints,
            alerts: []
        )
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
        if http.statusCode == 403 || http.statusCode == 429 {
            throw ProviderError.quota(id.displayName)
        }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
    }
}

// MARK: - 解码结构

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

        var comps = URLComponents(string: "https://restapi.amap.com/v3/weather/weatherInfo")!
        comps.queryItems = [
            .init(name: "key", value: apiKey),
            .init(name: "city", value: adcode),
            .init(name: "extensions", value: "all")
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }

        let raw: AMapWeatherResponse
        do {
            raw = try JSONDecoder().decode(AMapWeatherResponse.self, from: data)
        } catch {
            throw ProviderError.decoding(String(describing: error))
        }
        guard raw.status == "1", let forecast = raw.forecasts.first else {
            throw ProviderError.decoding(raw.info ?? "AMap 返回异常")
        }

        let casts = forecast.casts
        let today = casts.first
        let current = CurrentConditions(
            date: Date(),
            temperature: Double(today?.daytemp ?? "0") ?? 0,
            apparentTemperature: Double(today?.daytemp ?? "0") ?? 0,
            humidity: 0,
            pressureHPa: 1013,
            dewPoint: 0,
            visibilityMeters: 10_000,
            uvIndex: 0,
            windSpeed: 0,
            windDirection: 0,
            windGust: 0,
            cloudCover: 0,
            precipitation: 0,
            isDay: true,
            code: WeatherCodeMapper.wmo(fromAMap: today?.dayweather ?? "")
        )

        let dayPoints: [DayPoint] = casts.compactMap { c -> DayPoint? in
            guard let date = WallClock.date(from: c.date) else { return nil }
            return DayPoint(
                date: date,
                code: WeatherCodeMapper.wmo(fromAMap: c.dayweather),
                minTemperature: Double(c.nighttemp) ?? 0,
                maxTemperature: Double(c.daytemp) ?? 0,
                precipitationChance: 0,
                uvIndexMax: 0,
                windMax: 0,
                gustMax: 0
            )
        }

        return ProviderPayload(
            providerID: id,
            timezone: place.timezone ?? "Asia/Shanghai",
            current: current,
            hourly: [],
            daily: dayPoints,
            alerts: []
        )
    }

    private func adcode(for place: Place) async throws -> String {
        let key = String(format: "%.2f,%.2f", place.latitude, place.longitude)
        if let cached = adcodeCache[key] { return cached }

        var comps = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo")!
        comps.queryItems = [
            .init(name: "key", value: apiKey),
            .init(name: "location", value: "\(place.longitude),\(place.latitude)")
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, _) = try await session.data(from: url)
        let raw = try? JSONDecoder().decode(AMapRegeoResponse.self, from: data)
        guard let code = raw?.regeocode?.addressComponent.adcode, !code.isEmpty else {
            throw ProviderError.decoding("无法获取行政区划编码")
        }
        adcodeCache[key] = code
        return code
    }
}

struct AMapRegeoResponse: Decodable {
    struct Regeocode: Decodable {
        struct AddressComponent: Decodable {
            let adcode: String
        }
        let addressComponent: AddressComponent
    }
    let regeocode: Regeocode?
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
    let forecasts: [Forecast]
}

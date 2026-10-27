import Foundation

// MARK: - Open-Meteo（默认源，无需 Key）

final class OpenMeteoProvider: WeatherProvider {
    let id: ProviderID = .openMeteo
    let requiresAPIKey = false
    let capabilities: ProviderCapabilities = [.hourly, .daily]
    let attribution = ProviderID.openMeteo.attribution

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "WeatherBar/1.0 (macOS)"]
        session = URLSession(configuration: config)
    }

    func isConfigured() -> Bool { true }

    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,dew_point_2m,visibility,uv_index,wind_speed_10m,relative_humidity_2m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,daylight_duration,uv_index_max,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: String(max(days, 7))),
            .init(name: "wind_speed_unit", value: "kmh")
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }

        let raw: Response
        do {
            // 注意：不能使用 .convertFromSnakeCase —— 它会把 temperature_2m 转成 temperature2M，
            // 与属性名不匹配。这里全部使用显式 CodingKeys。
            raw = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            NSLog("WeatherBar OpenMeteo decode error: \(error)")
            throw ProviderError.decoding(String(describing: error))
        }
        return Self.makePayload(raw, place: place, hours: hours)
    }

    // MARK: 解码结构

    private struct Response: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature2m: Double?
            let relativeHumidity2m: Int?
            let apparentTemperature: Double?
            let isDay: Int?
            let precipitation: Double?
            let weatherCode: Int?
            let cloudCover: Int?
            let pressureMsl: Double?
            let windSpeed10m: Double?
            let windDirection10m: Double?
            let windGusts10m: Double?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature2m = "temperature_2m"
                case relativeHumidity2m = "relative_humidity_2m"
                case apparentTemperature = "apparent_temperature"
                case isDay = "is_day"
                case precipitation
                case weatherCode = "weather_code"
                case cloudCover = "cloud_cover"
                case pressureMsl = "pressure_msl"
                case windSpeed10m = "wind_speed_10m"
                case windDirection10m = "wind_direction_10m"
                case windGusts10m = "wind_gusts_10m"
            }
        }

        struct Hourly: Decodable {
            let time: [String]
            let temperature2m: [Double?]
            let weatherCode: [Int?]
            let precipitationProbability: [Int?]
            let dewPoint2m: [Double?]
            let visibility: [Double?]
            let uvIndex: [Double?]
            let windSpeed10m: [Double?]
            let relativeHumidity2m: [Int?]

            enum CodingKeys: String, CodingKey {
                case time
                case temperature2m = "temperature_2m"
                case weatherCode = "weather_code"
                case precipitationProbability = "precipitation_probability"
                case dewPoint2m = "dew_point_2m"
                case visibility
                case uvIndex = "uv_index"
                case windSpeed10m = "wind_speed_10m"
                case relativeHumidity2m = "relative_humidity_2m"
            }
        }

        struct Daily: Decodable {
            let time: [String]
            let weatherCode: [Int?]
            let temperature2mMax: [Double?]
            let temperature2mMin: [Double?]
            let sunrise: [String?]
            let sunset: [String?]
            let daylightDuration: [Double?]
            let uvIndexMax: [Double?]
            let precipitationProbabilityMax: [Int?]
            let windSpeed10mMax: [Double?]
            let windGusts10mMax: [Double?]

            enum CodingKeys: String, CodingKey {
                case time
                case weatherCode = "weather_code"
                case temperature2mMax = "temperature_2m_max"
                case temperature2mMin = "temperature_2m_min"
                case sunrise
                case sunset
                case daylightDuration = "daylight_duration"
                case uvIndexMax = "uv_index_max"
                case precipitationProbabilityMax = "precipitation_probability_max"
                case windSpeed10mMax = "wind_speed_10m_max"
                case windGusts10mMax = "wind_gusts_10m_max"
            }
        }

        let timezone: String
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    // MARK: 映射

    private static func makePayload(_ raw: Response, place: Place, hours: Int) -> ProviderPayload {
        let hourlyDates = raw.hourly.time.compactMap { WallClock.date(from: $0) }
        let nowDate = WallClock.date(from: raw.current.time) ?? Date()

        // 找到当前小时在 hourly 中的索引
        var startIndex = 0
        for (i, d) in hourlyDates.enumerated() where d >= nowDate {
            startIndex = i
            break
        }

        func at<T>(_ arr: [T?], _ i: Int) -> T? {
            guard i >= 0, i < arr.count else { return nil }
            return arr[i]
        }

        var hourPoints: [HourPoint] = []
        if startIndex < hourlyDates.count {
            let upper = min(startIndex + max(hours, 12), hourlyDates.count)
            for i in startIndex..<upper {
                hourPoints.append(HourPoint(
                    date: hourlyDates[i],
                    temperature: at(raw.hourly.temperature2m, i) ?? 0,
                    code: WeatherCode(raw: at(raw.hourly.weatherCode, i) ?? 2),
                    precipitationChance: at(raw.hourly.precipitationProbability, i) ?? 0,
                    windSpeed: at(raw.hourly.windSpeed10m, i) ?? 0,
                    humidity: at(raw.hourly.relativeHumidity2m, i) ?? 0
                ))
            }
        }

        var dayPoints: [DayPoint] = []
        for i in raw.daily.time.indices {
            guard let date = WallClock.date(from: raw.daily.time[i]) else { continue }
            dayPoints.append(DayPoint(
                date: date,
                code: WeatherCode(raw: at(raw.daily.weatherCode, i) ?? 2),
                minTemperature: at(raw.daily.temperature2mMin, i) ?? 0,
                maxTemperature: at(raw.daily.temperature2mMax, i) ?? 0,
                precipitationChance: at(raw.daily.precipitationProbabilityMax, i) ?? 0,
                uvIndexMax: at(raw.daily.uvIndexMax, i) ?? 0,
                windMax: at(raw.daily.windSpeed10mMax, i) ?? 0,
                gustMax: at(raw.daily.windGusts10mMax, i) ?? 0
            ))
        }

        let current = CurrentConditions(
            date: nowDate,
            temperature: raw.current.temperature2m ?? 0,
            apparentTemperature: raw.current.apparentTemperature ?? raw.current.temperature2m ?? 0,
            humidity: raw.current.relativeHumidity2m ?? 0,
            pressureHPa: raw.current.pressureMsl ?? 1013,
            dewPoint: at(raw.hourly.dewPoint2m, startIndex) ?? 0,
            visibilityMeters: at(raw.hourly.visibility, startIndex) ?? 10_000,
            uvIndex: at(raw.hourly.uvIndex, startIndex) ?? 0,
            windSpeed: raw.current.windSpeed10m ?? 0,
            windDirection: raw.current.windDirection10m ?? 0,
            windGust: raw.current.windGusts10m ?? 0,
            cloudCover: raw.current.cloudCover ?? 0,
            precipitation: raw.current.precipitation ?? 0,
            isDay: (raw.current.isDay ?? 1) == 1,
            code: WeatherCode(raw: raw.current.weatherCode ?? 2)
        )

        return ProviderPayload(
            providerID: .openMeteo,
            timezone: raw.timezone,
            current: current,
            hourly: hourPoints,
            daily: dayPoints,
            alerts: []
        )
    }
}

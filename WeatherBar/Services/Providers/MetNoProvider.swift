// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation

// MARK: - MET Norway（挪威气象局，免费且无需注册）

/// api.met.no 的 locationforecast 2.0 compact 接口：全球覆盖，只要请求头带一个能联系到的 User-Agent。
/// 逐小时数据覆盖前约 2.5 天，之后是 6 小时粒度；逐日数据由 timeseries 聚合。
final class MetNoProvider: WeatherProvider {
    let id: ProviderID = .metNorway
    let requiresAPIKey = false
    let capabilities: ProviderCapabilities = [.hourly, .daily]
    let attribution = ProviderID.metNorway.attribution

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        // MET Norway 要求带上可识别的 User-Agent
        config.httpAdditionalHeaders = [
            "User-Agent": "WeatherBar/1.0 (https://github.com/cat-clever/weatherbar)"
        ]
        session = URLSession(configuration: config)
    }

    func isConfigured() -> Bool { true }

    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload {
        var comps = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")!
        comps.queryItems = [
            .init(name: "lat", value: String(format: "%.4f", place.latitude)),
            .init(name: "lon", value: String(format: "%.4f", place.longitude))
        ]
        guard let url = comps.url else { throw ProviderError.network("无效 URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }

        let raw: Response
        do {
            raw = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            NSLog("WeatherBar MetNo decode error: \(error)")
            throw ProviderError.decoding(String(describing: error))
        }

        return try makePayload(raw, place: place, days: days)
    }

    // MARK: 解码结构

    private struct Response: Decodable {
        struct Properties: Decodable { let timeseries: [Entry] }
        struct Entry: Decodable {
            let time: String
            let data: Payload
        }
        struct Payload: Decodable {
            let instant: Instant
            let next1: Step?
            let next6: Step?

            enum CodingKeys: String, CodingKey {
                case instant
                case next1 = "next_1_hours"
                case next6 = "next_6_hours"
            }
        }
        struct Instant: Decodable { let details: Details }
        struct Step: Decodable {
            let summary: Summary?
            let details: StepDetails?
        }
        struct Summary: Decodable {
            let symbolCode: String
            enum CodingKeys: String, CodingKey { case symbolCode = "symbol_code" }
        }
        struct StepDetails: Decodable {
            let precipitationAmount: Double?
            enum CodingKeys: String, CodingKey { case precipitationAmount = "precipitation_amount" }
        }
        struct Details: Decodable {
            let airTemperature: Double?
            let relativeHumidity: Double?
            let windSpeed: Double?
            let windFromDirection: Double?
            let airPressureAtSeaLevel: Double?
            let cloudAreaFraction: Double?
            let dewPointTemperature: Double?

            enum CodingKeys: String, CodingKey {
                case airTemperature = "air_temperature"
                case relativeHumidity = "relative_humidity"
                case windSpeed = "wind_speed"
                case windFromDirection = "wind_from_direction"
                case airPressureAtSeaLevel = "air_pressure_at_sea_level"
                case cloudAreaFraction = "cloud_area_fraction"
                case dewPointTemperature = "dew_point_temperature"
            }
        }

        let properties: Properties
    }

    // MARK: 映射

    private struct Sample {
        let date: Date          // 墙钟时间
        let temperature: Double
        let humidity: Int
        let windKmh: Double
        let windDirection: Double
        let pressure: Double?
        let cloudCover: Int
        let dewPoint: Double?
        let precipitation: Double
        let code: WeatherCode
        let isDay: Bool
    }

    private func makePayload(_ raw: Response, place: Place, days: Int) throws -> ProviderPayload {
        let timeZone = TimeZone(identifier: place.timezone ?? "") ?? .current
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var samples: [Sample] = []
        for entry in raw.properties.timeseries {
            guard let instant = formatter.date(from: entry.time) else { continue }
            // 真实时间 → 墙钟时间（本项目所有时间都按「墙钟时间存在 UTC 容器里」处理）
            let offset = TimeInterval(timeZone.secondsFromGMT(for: instant))
            let wall = instant.addingTimeInterval(offset)
            let details = entry.data.instant.details
            let symbol = entry.data.next1?.summary?.symbolCode ?? entry.data.next6?.summary?.symbolCode ?? "cloudy"
            let amount = entry.data.next1?.details?.precipitationAmount
                ?? entry.data.next6?.details?.precipitationAmount
                ?? 0

            samples.append(Sample(
                date: wall,
                temperature: details.airTemperature ?? 0,
                humidity: Int((details.relativeHumidity ?? 0).rounded()),
                windKmh: (details.windSpeed ?? 0) * 3.6,
                windDirection: details.windFromDirection ?? 0,
                pressure: details.airPressureAtSeaLevel,
                cloudCover: Int((details.cloudAreaFraction ?? 0).rounded()),
                dewPoint: details.dewPointTemperature,
                precipitation: amount,
                code: Self.code(from: symbol),
                isDay: symbol.hasSuffix("_day") || (!symbol.hasSuffix("_night") && Self.isDaytime(wall))
            ))
        }

        guard !samples.isEmpty else { throw ProviderError.decoding("MET Norway 返回为空") }

        // 逐小时：只取 1 小时粒度的连续段
        var hourly: [HourPoint] = []
        for (index, sample) in samples.enumerated() {
            if index > 0 {
                let gap = sample.date.timeIntervalSince(samples[index - 1].date)
                if gap > 3_600 * 1.5 { break }
            }
            hourly.append(HourPoint(
                date: sample.date,
                temperature: sample.temperature,
                code: sample.code,
                precipitationChance: sample.precipitation > 0 ? min(90, 40 + Int(sample.precipitation * 20)) : 0,
                windSpeed: sample.windKmh,
                humidity: sample.humidity,
                pressureHPa: sample.pressure,
                dewPoint: sample.dewPoint,
                uvIndex: nil,
                apparentTemperature: nil,
                precipitation: sample.precipitation,
                cloudCover: sample.cloudCover
            ))
        }

        // 逐日：把整段 timeseries 按墙钟日聚合
        var daily: [DayPoint] = []
        var buckets: [Date: [Sample]] = [:]
        for sample in samples {
            buckets[WallClock.startOfDay(sample.date), default: []].append(sample)
        }
        for dayStart in buckets.keys.sorted().prefix(max(days, 7)) {
            guard let group = buckets[dayStart], !group.isEmpty else { continue }
            let temps = group.map(\.temperature)
            let wettest = group.map(\.precipitation).max() ?? 0
            // 取中午附近（或最接近 12 点）的天气现象作为当天代表
            let representative = group.min { abs($0.date.timeIntervalSince(dayStart.addingTimeInterval(43_200)))
                < abs($1.date.timeIntervalSince(dayStart.addingTimeInterval(43_200))) }
            daily.append(DayPoint(
                date: dayStart,
                code: representative?.code ?? .partlyCloudy,
                minTemperature: temps.min() ?? 0,
                maxTemperature: temps.max() ?? 0,
                precipitationChance: wettest > 0 ? min(90, 40 + Int(wettest * 20)) : 0,
                uvIndexMax: 0,
                windMax: group.map(\.windKmh).max() ?? 0,
                gustMax: group.map(\.windKmh).max() ?? 0
            ))
        }

        // 实况取离现在最近的那个时刻
        let now = wallNow(timeZone: timeZone)
        let currentSample = samples.min {
            abs($0.date.timeIntervalSince(now)) < abs($1.date.timeIntervalSince(now))
        } ?? samples[0]
        let current = CurrentConditions(
            date: currentSample.date,
            temperature: currentSample.temperature,
            apparentTemperature: currentSample.temperature,
            humidity: currentSample.humidity,
            pressureHPa: currentSample.pressure ?? 1013,
            dewPoint: currentSample.dewPoint ?? currentSample.temperature,
            visibilityMeters: 10_000,
            uvIndex: 0,
            windSpeed: currentSample.windKmh,
            windDirection: currentSample.windDirection,
            windGust: currentSample.windKmh,
            cloudCover: currentSample.cloudCover,
            precipitation: currentSample.precipitation,
            isDay: currentSample.isDay,
            code: currentSample.code
        )

        return ProviderPayload(
            providerID: .metNorway,
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

    private static func isDaytime(_ wall: Date) -> Bool {
        let hour = WallClock.hour(of: wall)
        return hour >= 6 && hour < 18
    }

    /// MET 的 symbol_code → WMO 天气代码
    private static func code(from symbol: String) -> WeatherCode {
        let base = symbol
            .replacingOccurrences(of: "_day", with: "")
            .replacingOccurrences(of: "_night", with: "")
            .replacingOccurrences(of: "_polartwilight", with: "")

        switch base {
        case "clearsky": return .clear
        case "fair": return .mainlyClear
        case "partlycloudy": return .partlyCloudy
        case "cloudy": return .overcast
        case "fog": return .fog
        case "lightrain": return .rainLight
        case "rain": return .rainModerate
        case "heavyrain": return .rainHeavy
        case "lightrainshowers": return .rainShowersLight
        case "rainshowers": return .rainShowersModerate
        case "heavyrainshowers": return .rainShowersViolent
        case "lightsleet", "sleet": return .freezingRainLight
        case "heavysleet": return .freezingRainHeavy
        case "lightsnow": return .snowLight
        case "snow": return .snowModerate
        case "heavysnow": return .snowHeavy
        case "lightsnowshowers", "snowshowers": return .snowShowersLight
        case "heavysnowshowers": return .snowShowersHeavy
        case "rainandthunder", "heavyrainandthunder": return .thunderstorm
        case "sleetandthunder", "snowandthunder": return .thunderstormHail
        default: return .partlyCloudy
        }
    }
}

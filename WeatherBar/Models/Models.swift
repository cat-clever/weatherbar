import Foundation

// MARK: - 地区

struct Place: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var admin1: String?
    var country: String?
    var latitude: Double
    var longitude: Double
    var timezone: String?
    var isCurrentLocation: Bool

    init(id: UUID = UUID(),
         name: String,
         admin1: String? = nil,
         country: String? = nil,
         latitude: Double,
         longitude: Double,
         timezone: String? = nil,
         isCurrentLocation: Bool = false) {
        self.id = id
        self.name = name
        self.admin1 = admin1
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.isCurrentLocation = isCurrentLocation
    }

    var displayName: String { name }

    var subtitle: String {
        [admin1, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != name }
            .joined(separator: " · ")
    }

    func isSameLocation(as other: Place) -> Bool {
        abs(latitude - other.latitude) < 0.01 && abs(longitude - other.longitude) < 0.01
    }

    static let fallback = Place(name: "上海",
                                admin1: "上海市",
                                country: "中国",
                                latitude: 31.2304,
                                longitude: 121.4737,
                                timezone: "Asia/Shanghai")
}

// MARK: - 天气代码（WMO）

enum WeatherCode: Int, Codable, Sendable, CaseIterable {
    case clear = 0
    case mainlyClear = 1
    case partlyCloudy = 2
    case overcast = 3
    case fog = 45
    case rimeFog = 48
    case drizzleLight = 51
    case drizzleModerate = 53
    case drizzleDense = 55
    case freezingDrizzleLight = 56
    case freezingDrizzleDense = 57
    case rainLight = 61
    case rainModerate = 63
    case rainHeavy = 65
    case freezingRainLight = 66
    case freezingRainHeavy = 67
    case snowLight = 71
    case snowModerate = 73
    case snowHeavy = 75
    case snowGrains = 77
    case rainShowersLight = 80
    case rainShowersModerate = 81
    case rainShowersViolent = 82
    case snowShowersLight = 85
    case snowShowersHeavy = 86
    case thunderstorm = 95
    case thunderstormHail = 96
    case thunderstormHailHeavy = 99

    init(raw: Int) {
        self = WeatherCode(rawValue: raw) ?? .partlyCloudy
    }

    func symbolName(isDay: Bool) -> String {
        switch self {
        case .clear, .mainlyClear:
            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy:
            return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast:
            return "cloud.fill"
        case .fog, .rimeFog:
            return "cloud.fog.fill"
        case .drizzleLight, .drizzleModerate, .drizzleDense,
             .freezingDrizzleLight, .freezingDrizzleDense:
            return "cloud.drizzle.fill"
        case .rainLight, .rainModerate, .rainHeavy:
            return "cloud.rain.fill"
        case .freezingRainLight, .freezingRainHeavy:
            return "cloud.sleet.fill"
        case .snowLight, .snowModerate, .snowHeavy, .snowGrains,
             .snowShowersLight, .snowShowersHeavy:
            return "cloud.snow.fill"
        case .rainShowersLight, .rainShowersModerate, .rainShowersViolent:
            return "cloud.heavyrain.fill"
        case .thunderstorm, .thunderstormHail, .thunderstormHailHeavy:
            return "cloud.bolt.rain.fill"
        }
    }

    var localizedDescription: String {
        switch self {
        case .clear: return "晴"
        case .mainlyClear: return "晴间多云"
        case .partlyCloudy: return "局部多云"
        case .overcast: return "阴"
        case .fog: return "雾"
        case .rimeFog: return "雾凇"
        case .drizzleLight: return "小毛毛雨"
        case .drizzleModerate: return "毛毛雨"
        case .drizzleDense: return "浓毛毛雨"
        case .freezingDrizzleLight: return "冻毛毛雨"
        case .freezingDrizzleDense: return "强冻毛毛雨"
        case .rainLight: return "小雨"
        case .rainModerate: return "中雨"
        case .rainHeavy: return "大雨"
        case .freezingRainLight: return "冻雨"
        case .freezingRainHeavy: return "强冻雨"
        case .snowLight: return "小雪"
        case .snowModerate: return "中雪"
        case .snowHeavy: return "大雪"
        case .snowGrains: return "雪粒"
        case .rainShowersLight: return "阵雨"
        case .rainShowersModerate: return "中阵雨"
        case .rainShowersViolent: return "强阵雨"
        case .snowShowersLight: return "小阵雪"
        case .snowShowersHeavy: return "大阵雪"
        case .thunderstorm: return "雷阵雨"
        case .thunderstormHail: return "雷阵雨伴冰雹"
        case .thunderstormHailHeavy: return "强雷暴伴冰雹"
        }
    }

    var isPrecipitation: Bool {
        switch self {
        case .clear, .mainlyClear, .partlyCloudy, .overcast, .fog, .rimeFog:
            return false
        default:
            return true
        }
    }
}

// MARK: - 单位

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }
    var label: String { self == .celsius ? "摄氏度 °C" : "华氏度 °F" }

    func convert(fromCelsius c: Double) -> Double {
        self == .celsius ? c : c * 9 / 5 + 32
    }
}

enum WindUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case kmh, ms, mph
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kmh: return "公里/小时"
        case .ms: return "米/秒"
        case .mph: return "英里/小时"
        }
    }
    var shortLabel: String {
        switch self {
        case .kmh: return "km/h"
        case .ms: return "m/s"
        case .mph: return "mph"
        }
    }
    func convert(fromKmh v: Double) -> Double {
        switch self {
        case .kmh: return v
        case .ms: return v / 3.6
        case .mph: return v / 1.609344
        }
    }
}

enum PressureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case hpa, inhg, mmhg
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hpa: return "百帕"
        case .inhg: return "英寸汞柱"
        case .mmhg: return "毫米汞柱"
        }
    }
    func convert(fromHPa v: Double) -> Double {
        switch self {
        case .hpa: return v
        case .inhg: return v * 0.02953
        case .mmhg: return v * 0.750062
        }
    }
}

// MARK: - 天气数据

struct CurrentConditions: Codable, Sendable {
    var date: Date
    var temperature: Double          // 摄氏
    var apparentTemperature: Double
    var humidity: Int
    var pressureHPa: Double
    var dewPoint: Double
    var visibilityMeters: Double
    var uvIndex: Double
    var windSpeed: Double            // km/h
    var windDirection: Double        // 0...360
    var windGust: Double
    var cloudCover: Int
    var precipitation: Double
    var isDay: Bool
    var code: WeatherCode
}

struct HourPoint: Codable, Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var temperature: Double
    var code: WeatherCode
    var precipitationChance: Int
    var windSpeed: Double
    var humidity: Int

    // 曲线可切换的其余指标（老缓存 / 部分数据源可能没有）
    var pressureHPa: Double?
    var dewPoint: Double?
    var uvIndex: Double?
    var apparentTemperature: Double?
    var precipitation: Double?
    var cloudCover: Int?
}

struct DayPoint: Codable, Sendable, Identifiable {
    var id: Date { date }
    var date: Date
    var code: WeatherCode
    var minTemperature: Double
    var maxTemperature: Double
    var precipitationChance: Int
    var uvIndexMax: Double
    var windMax: Double
    var gustMax: Double
}

struct MoonPhase: Codable, Sendable {
    var age: Double
    var illumination: Double
    var distanceKm: Double

    var name: String {
        let a = age.truncatingRemainder(dividingBy: 29.530588853)
        switch a {
        case ..<1.85: return "新月"
        case ..<5.54: return "娥眉月"
        case ..<9.23: return "上弦月"
        case ..<12.91: return "盈凸月"
        case ..<16.61: return "满月"
        case ..<20.30: return "亏凸月"
        case ..<23.99: return "下弦月"
        default: return "残月"
        }
    }
}

struct AstroInfo: Codable, Sendable {
    var sunrise: Date?
    var sunset: Date?
    var solarNoon: Date?
    var moonrise: Date?
    var moonset: Date?
    var moonPhase: MoonPhase
    var civilDawn: Date?
    var civilDusk: Date?
    var nauticalDawn: Date?
    var nauticalDusk: Date?
    var astronomicalDawn: Date?
    var astronomicalDusk: Date?
    var goldenHourMorning: Date?
    var goldenHourEvening: Date?
    var blueHourMorning: Date?
    var blueHourEvening: Date?
    var daylightSeconds: Double?
    var daylightDelta: Double?

    // 当前天体位置（老缓存里没有，解码为 nil）
    var sunAltitude: Double?
    var sunAzimuth: Double?
    var sunDistanceKm: Double?
    var moonAltitude: Double?
    var moonAzimuth: Double?

    static let empty = AstroInfo(moonPhase: MoonPhase(age: 0, illumination: 0, distanceKm: 384_400))
}

struct WeatherAlert: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    var severity: String
    var summary: String
}

struct WeatherSnapshot: Codable, Sendable {
    var place: Place
    var fetchedAt: Date
    var servedBy: ProviderID
    var timezone: String
    var current: CurrentConditions
    var hourly: [HourPoint]
    var daily: [DayPoint]
    var astro: AstroInfo
    var alerts: [WeatherAlert]
}

struct ProviderPayload: Sendable {
    var providerID: ProviderID
    var timezone: String
    var current: CurrentConditions
    var hourly: [HourPoint]
    var daily: [DayPoint]
    var alerts: [WeatherAlert]
}

// MARK: - 墙钟时间（天气 API 返回的都是当地墙钟时间，统一按 UTC 容器处理）

enum WallClock {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "zh_Hans_CN")
        return c
    }()

    static let timeZone = TimeZone(identifier: "UTC")!

    static func date(from string: String) -> Date? {
        let formats = ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss"]
        for f in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = timeZone
            df.dateFormat = f
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }
}

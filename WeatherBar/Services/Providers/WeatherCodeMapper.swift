import Foundation

/// 各家天气现象 → 内部 WMO 码
enum WeatherCodeMapper {

    // MARK: 和风天气 icon

    static func wmo(fromQWeather icon: String) -> WeatherCode {
        switch icon {
        case "100", "150": return .clear
        case "102", "152": return .mainlyClear
        case "101", "103", "153": return .partlyCloudy
        case "104", "154": return .overcast
        case "300", "301", "350", "351": return .rainShowersLight
        case "302", "303": return .thunderstorm
        case "304": return .thunderstormHail
        case "305", "309": return .rainLight
        case "306", "314": return .rainModerate
        case "307", "315": return .rainHeavy
        case "308", "310", "311", "312", "316", "317", "318": return .rainShowersViolent
        case "313": return .freezingRainLight
        case "400", "407", "408", "409", "410", "499": return .snowLight
        case "401", "402", "403": return .snowModerate
        case "404", "405", "406", "456", "457": return .snowHeavy
        case "500", "501", "509", "510", "511", "512", "513", "514", "515": return .fog
        case "502", "503", "504", "507", "508": return .fog
        case "900": return .clear
        case "901": return .overcast
        case "999": return .partlyCloudy
        default: return .partlyCloudy
        }
    }

    // MARK: 心知天气 code

    static func wmo(fromSeniverse code: String) -> WeatherCode {
        switch code {
        case "0": return .clear
        case "1": return .partlyCloudy
        case "2": return .overcast
        case "3": return .rainShowersLight
        case "4": return .thunderstorm
        case "5": return .thunderstormHail
        case "6": return .freezingRainLight
        case "7", "21": return .rainLight
        case "8", "22": return .rainModerate
        case "9", "23": return .rainHeavy
        case "10", "24", "25": return .rainShowersViolent
        case "11", "12": return .rainShowersViolent
        case "13", "26": return .snowShowersLight
        case "14", "27": return .snowLight
        case "15", "28": return .snowModerate
        case "16", "17": return .snowHeavy
        case "18", "32", "37": return .fog
        case "19": return .freezingRainLight
        case "20", "29", "30", "31": return .fog
        case "33", "34", "35", "36", "38": return .fog
        default: return .partlyCloudy
        }
    }

    // MARK: 高德天气文本

    static func wmo(fromAMap text: String) -> WeatherCode {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("雷") { return .thunderstorm }
        if t.contains("暴雪") { return .snowHeavy }
        if t.contains("大雪") { return .snowHeavy }
        if t.contains("中雪") { return .snowModerate }
        if t.contains("雪") { return .snowLight }
        if t.contains("暴雨") { return .rainShowersViolent }
        if t.contains("大雨") { return .rainHeavy }
        if t.contains("中雨") { return .rainModerate }
        if t.contains("小雨") { return .rainLight }
        if t.contains("阵雨") { return .rainShowersLight }
        if t.contains("雨") { return .rainLight }
        if t.contains("雾") || t.contains("霾") { return .fog }
        if t.contains("沙") || t.contains("尘") { return .fog }
        if t.contains("阴") { return .overcast }
        if t.contains("多云") { return .partlyCloudy }
        if t.contains("晴") { return .clear }
        return .partlyCloudy
    }

    // MARK: WeatherKit conditionCode

    static func wmo(fromWeatherKit condition: String) -> WeatherCode {
        switch condition.lowercased() {
        case "clear": return .clear
        case "mostlyclear": return .mainlyClear
        case "partlycloudy": return .partlyCloudy
        case "mostlycloudy", "cloudy": return .overcast
        case "foggy", "haze", "smoky", "blowingdust": return .fog
        case "breezy", "windy": return .overcast
        case "drizzle": return .drizzleLight
        case "rain": return .rainLight
        case "heavyrain": return .rainHeavy
        case "freezingdrizzle": return .freezingDrizzleLight
        case "freezingrain", "sleet": return .freezingRainLight
        case "snow", "flurries": return .snowLight
        case "heavysnow", "blizzard", "blowingsnow": return .snowHeavy
        case "sunshowers": return .rainShowersLight
        case "isolatedthunderstorms", "scatteredthunderstorms",
             "thunderstorms", "strongstorms": return .thunderstorm
        case "hail": return .thunderstormHail
        case "tropicalstorm", "hurricane": return .thunderstormHailHeavy
        default: return .partlyCloudy
        }
    }

    // MARK: 风描述

    static func windDescription(_ kmh: Double) -> String {
        switch kmh {
        case ..<12: return "微风"
        case ..<20: return "轻微风"
        case ..<29: return "和风"
        case ..<39: return "清劲风"
        default: return "强风"
        }
    }

    /// 「局部多云。轻微风，阵风高达 41 公里/小时。」
    static func summary(code: WeatherCode, windMax: Double, gustMax: Double) -> String {
        var text = "\(code.localizedDescription)。\(windDescription(windMax))"
        if gustMax >= 20 {
            text += "，阵风高达 \(Int(gustMax.rounded())) 公里/小时"
        }
        text += "。"
        return text
    }
}

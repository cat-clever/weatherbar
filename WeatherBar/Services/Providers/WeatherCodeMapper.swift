// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation

/// 各家天气现象 → 内部 WMO 码
enum WeatherCodeMapper {

    // MARK: 和风天气 icon

    static func wmo(fromQWeather icon: String) -> WeatherCode {
        switch icon {
        case "100", "150": return .clear
        case "102", "152": return .mainlyClear
        case "101", "103", "151", "153": return .partlyCloudy
        case "104", "154": return .overcast
        case "300", "350": return .rainShowersLight
        case "301", "351": return .rainShowersModerate
        case "302", "303": return .thunderstorm
        case "304": return .thunderstormHail
        case "305", "399": return .rainLight
        case "309": return .drizzleLight
        case "306", "314": return .rainModerate
        case "307", "315": return .rainHeavy
        case "308", "310", "311", "312", "316", "317", "318": return .rainShowersViolent
        case "313": return .freezingRainLight
        case "400", "499": return .snowLight
        case "401", "408": return .snowModerate
        case "402", "403", "409", "410": return .snowHeavy
        case "404", "405", "406", "456": return .freezingRainLight
        case "407", "457": return .snowShowersLight
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
        case "0", "1", "2", "3", "38": return .clear
        case "5", "6": return .mainlyClear
        case "4", "7", "8": return .partlyCloudy
        case "9", "32", "33", "37": return .overcast
        case "10": return .rainShowersLight
        case "11": return .thunderstorm
        case "12": return .thunderstormHail
        case "13": return .rainLight
        case "14": return .rainModerate
        case "15": return .rainHeavy
        case "16", "17", "18": return .rainShowersViolent
        case "19", "20": return .freezingRainLight
        case "21": return .snowShowersLight
        case "22": return .snowLight
        case "23": return .snowModerate
        case "24", "25": return .snowHeavy
        case "26", "27", "28", "29", "30", "31": return .fog
        case "34", "35", "36": return .thunderstormHailHeavy
        default: return .partlyCloudy
        }
    }

    // MARK: 高德天气文本

    static func wmo(fromAMap text: String) -> WeatherCode {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("冰雹") { return .thunderstormHail }
        if t.contains("雷") { return .thunderstorm }
        if t.contains("雨夹雪") || t.contains("雨雪") || t.contains("冻雨") { return .freezingRainLight }
        if t.contains("暴雪") || t.contains("大雪") { return .snowHeavy }
        if t.contains("中雪") { return .snowModerate }
        if t.contains("阵雪") { return .snowShowersLight }
        if t.contains("雪") { return .snowLight }
        if t.contains("暴雨") || t.contains("极端降雨") || t.contains("强阵雨") { return .rainShowersViolent }
        if t.contains("大雨") { return .rainHeavy }
        if t.contains("中雨") { return .rainModerate }
        if t.contains("阵雨") { return .rainShowersLight }
        if t.contains("毛毛雨") || t.contains("细雨") { return .drizzleLight }
        if t.contains("小雨") || t.contains("雨") { return .rainLight }
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
        case "clear", "hot", "frigid": return .clear
        case "mostlyclear": return .mainlyClear
        case "partlycloudy": return .partlyCloudy
        case "mostlycloudy", "cloudy": return .overcast
        case "foggy", "haze", "smoky", "blowingdust": return .fog
        case "breezy", "windy": return .overcast
        case "drizzle": return .drizzleLight
        case "rain": return .rainLight
        case "heavyrain": return .rainHeavy
        case "freezingdrizzle": return .freezingDrizzleLight
        case "freezingrain", "sleet", "wintrymix": return .freezingRainLight
        case "snow", "flurries": return .snowLight
        case "sunflurries": return .snowShowersLight
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

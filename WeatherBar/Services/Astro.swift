// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation

// MARK: - 天文计算（太阳 / 月亮 / 月相）

/// 天体在地平坐标系中的位置
struct SkyPosition: Sendable {
    var altitude: Double     // 地平高度（度），负值为地平线下
    var azimuth: Double      // 方位角（度），0=正北，顺时针
    var distanceKm: Double
}

struct AstroCalculator {

    private let rad = Double.pi / 180
    private let synodicMonth = 29.530588853

    func compute(for instant: Date, place: Place, timezoneIdentifier: String? = nil) -> AstroInfo {
        let tz = TimeZone(identifier: timezoneIdentifier ?? place.timezone ?? "") ?? .current
        let wallInstant = instant.addingTimeInterval(TimeInterval(tz.secondsFromGMT(for: instant)))
        let dayStart = WallClock.startOfDay(wallInstant)
        return computeDay(wallDayStart: dayStart, skyInstant: instant, place: place, timeZone: tz)
    }

    /// 供悬停未来日期使用：`wallDate` 已是「墙钟日期存 UTC 容器」，只算该日升降时刻，不再把 00:00Z 当作真实观测时刻
    func computeForWallDay(_ wallDate: Date, place: Place, timezoneIdentifier: String? = nil) -> AstroInfo {
        let tz = TimeZone(identifier: timezoneIdentifier ?? place.timezone ?? "") ?? .current
        let dayStart = WallClock.startOfDay(wallDate)
        let roughOffset = tz.secondsFromGMT(for: dayStart)
        let noonInstant = dayStart.addingTimeInterval(43_200 - TimeInterval(roughOffset))
        return computeDay(wallDayStart: dayStart, skyInstant: noonInstant, place: place, timeZone: tz)
    }

    private func computeDay(wallDayStart dayStart: Date, skyInstant: Date, place: Place, timeZone tz: TimeZone) -> AstroInfo {
        // 用当地正午计算时区偏移，避免夏令时在凌晨切换造成 1 小时误差
        let roughOffset = tz.secondsFromGMT(for: skyInstant)
        let noonInstant = dayStart.addingTimeInterval(43_200 - TimeInterval(roughOffset))
        let offsetMinutes = Double(tz.secondsFromGMT(for: noonInstant)) / 60.0

        let sunEvents = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                  altitude: -0.833, offsetMinutes: offsetMinutes)
        let sunrise = sunEvents.rise
        let sunset = sunEvents.set

        let civil = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                              altitude: -6, offsetMinutes: offsetMinutes)
        let nautical = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                 altitude: -12, offsetMinutes: offsetMinutes)
        let astronomical = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                     altitude: -18, offsetMinutes: offsetMinutes)

        let blueMorning = civil.rise
        let goldenMorning = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                      altitude: -4, offsetMinutes: offsetMinutes).rise
        let goldenEveningStart = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                           altitude: 6, offsetMinutes: offsetMinutes).set
        let blueEveningEnd = civil.set

        let solarNoonMinutes = 720.0 - 4.0 * place.longitude - solarParams(julianDay(noonInstant)).eqTime + offsetMinutes
        let solarNoon = dayStart.addingTimeInterval(solarNoonMinutes * 60)

        let moonTimes = moonRiseSet(wallDayStart: dayStart, lat: place.latitude, lon: place.longitude, offsetMinutes: offsetMinutes)
        let phase = moonPhase(for: skyInstant)

        let sunNow = sunPosition(skyInstant, lat: place.latitude, lon: place.longitude)
        let moonNow = moonSkyPosition(skyInstant, lat: place.latitude, lon: place.longitude)

        var daylight: Double?
        if let sunrise, let sunset {
            daylight = max(0, sunset.timeIntervalSince(sunrise))
        }

        var delta: Double?
        if let todaySunrise = sunrise, let todaySunset = sunset {
            let yesterday = dayStart.addingTimeInterval(-86_400)
            let yNoon = yesterday.addingTimeInterval(43_200 - TimeInterval(roughOffset))
            let yOffsetMinutes = Double(tz.secondsFromGMT(for: yNoon)) / 60.0
            let ySun = eventTime(dayStart: yesterday, lat: place.latitude, lon: place.longitude,
                                 altitude: -0.833, offsetMinutes: yOffsetMinutes)
            if let yRise = ySun.rise, let ySet = ySun.set {
                delta = todaySunset.timeIntervalSince(todaySunrise) - ySet.timeIntervalSince(yRise)
            }
        }

        return AstroInfo(
            sunrise: sunrise,
            sunset: sunset,
            solarNoon: solarNoon,
            moonrise: moonTimes.rise,
            moonset: moonTimes.set,
            moonPhase: phase,
            civilDawn: civil.rise,
            civilDusk: civil.set,
            nauticalDawn: nautical.rise,
            nauticalDusk: nautical.set,
            astronomicalDawn: astronomical.rise,
            astronomicalDusk: astronomical.set,
            goldenHourMorning: goldenMorning,
            goldenHourEvening: goldenEveningStart,
            blueHourMorning: blueMorning,
            blueHourEvening: blueEveningEnd,
            daylightSeconds: daylight,
            daylightDelta: delta,
            sunAltitude: sunNow.altitude,
            sunAzimuth: sunNow.azimuth,
            sunDistanceKm: sunNow.distanceKm,
            moonAltitude: moonNow.altitude,
            moonAzimuth: moonNow.azimuth
        )
    }

    // MARK: - 当前天体位置（供左栏卡片使用）

    /// 太阳当前的地平高度 / 方位 / 地日距离
    func sunPosition(_ date: Date, lat: Double, lon: Double) -> SkyPosition {
        let jd = julianDay(date)
        let params = solarParams(jd)
        let altitude = Self.altitude(decl: params.decl, hourAngle: hourAngle(date, lon: lon, eqTime: params.eqTime), lat: lat)
        let azimuth = Self.azimuth(decl: params.decl, hourAngle: hourAngle(date, lon: lon, eqTime: params.eqTime), lat: lat)
        return SkyPosition(altitude: altitude, azimuth: azimuth, distanceKm: sunDistanceKm(jd))
    }

    /// 太阳在任意时刻的地平高度（画轨迹曲线用）
    func sunAltitude(_ date: Date, lat: Double, lon: Double) -> Double {
        let params = solarParams(julianDay(date))
        return Self.altitude(decl: params.decl, hourAngle: hourAngle(date, lon: lon, eqTime: params.eqTime), lat: lat)
    }

    /// 月亮当前的地平高度 / 方位 / 地月距离
    func moonSkyPosition(_ date: Date, lat: Double, lon: Double) -> SkyPosition {
        let jd = julianDay(date)
        let pos = moonPosition(jd)
        let hourAngle = localSidereal(jd) + lon - pos.ra / rad
        return SkyPosition(altitude: Self.altitude(decl: pos.dec / rad, hourAngle: hourAngle, lat: lat),
                           azimuth: Self.azimuth(decl: pos.dec / rad, hourAngle: hourAngle, lat: lat),
                           distanceKm: pos.distance)
    }

    /// 月亮在任意时刻的地平高度（画轨迹曲线用）
    func moonAltitudeAt(_ date: Date, lat: Double, lon: Double) -> Double {
        moonAltitude(date, lat: lat, lon: lon)
    }

    // MARK: - 位置换算

    /// 时角（度）：正午为 0，下午为正
    private func hourAngle(_ date: Date, lon: Double, eqTime: Double) -> Double {
        let utcMinutes = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        var solarMinutes = utcMinutes + 4 * lon + eqTime
        solarMinutes = solarMinutes.truncatingRemainder(dividingBy: 1440)
        if solarMinutes < 0 { solarMinutes += 1440 }
        return solarMinutes / 4 - 180
    }

    /// 格林尼治恒星时（度）
    private func localSidereal(_ jd: Double) -> Double {
        let d = jd - 2_451_545.0
        return (280.16 + 360.9856235 * d).truncatingRemainder(dividingBy: 360)
    }

    private static func altitude(decl: Double, hourAngle: Double, lat: Double) -> Double {
        let rad = Double.pi / 180
        let latRad = lat * rad
        let declRad = decl * rad
        let h = hourAngle * rad
        let sinAlt = sin(latRad) * sin(declRad) + cos(latRad) * cos(declRad) * cos(h)
        return asin(max(-1, min(1, sinAlt))) / rad
    }

    private static func azimuth(decl: Double, hourAngle: Double, lat: Double) -> Double {
        let rad = Double.pi / 180
        let latRad = lat * rad
        let declRad = decl * rad
        let h = hourAngle * rad
        let y = sin(h)
        let x = cos(h) * sin(latRad) - tan(declRad) * cos(latRad)
        var az = atan2(y, x) / rad + 180
        if az < 0 { az += 360 }
        if az >= 360 { az -= 360 }
        return az
    }

    /// 地日距离（公里）：1 AU = 149,597,870.7 km
    private func sunDistanceKm(_ jd: Double) -> Double {
        let g = (357.5291 + 0.98560028 * (jd - 2_451_545.0)) * rad
        let au = 1.00014 - 0.01671 * cos(g) - 0.00014 * cos(2 * g)
        return au * 149_597_870.7
    }

    // MARK: - 太阳

    private func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
    }

    private func solarParams(_ jd: Double) -> (decl: Double, eqTime: Double) {
        let t = (jd - 2_451_545.0) / 36_525.0
        let l0 = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m * rad) * (0.019993 - 0.000101 * t)
            + sin(3 * m * rad) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * t
        let lambda = trueLong - 0.00569 - 0.00478 * sin(omega * rad)
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(omega * rad)
        let decl = asin(sin(eps * rad) * sin(lambda * rad)) / rad
        let y = pow(tan(eps * rad / 2), 2)
        // 注意：方括号里是弧度，换算成分钟要先转角度再 ×4（1° = 4 分钟）
        let eqTimeRad = y * sin(2 * l0 * rad)
            - 2 * e * sin(m * rad)
            + 4 * e * y * sin(m * rad) * cos(2 * l0 * rad)
            - 0.5 * y * y * sin(4 * l0 * rad)
            - 1.25 * e * e * sin(2 * m * rad)
        let eqTime = 4 * eqTimeRad * (180 / Double.pi)
        return (decl, eqTime)
    }

    private func eventTime(dayStart: Date,
                           lat: Double,
                           lon: Double,
                           altitude: Double,
                           offsetMinutes: Double) -> (rise: Date?, set: Date?) {
        // 用当地正午对应的真实 UTC 算太阳赤纬与时差
        let noonInstant = dayStart.addingTimeInterval((720.0 - offsetMinutes) * 60)
        let jd = julianDay(noonInstant)
        let params = solarParams(jd)
        let latRad = lat * rad
        let declRad = params.decl * rad
        let cosH = (sin(altitude * rad) - sin(latRad) * sin(declRad)) / (cos(latRad) * cos(declRad))

        guard cosH >= -1, cosH <= 1 else {
            return (nil, nil)   // 极昼 / 极夜
        }
        let hourAngle = acos(cosH) / rad
        let noonMinutes = 720.0 - 4.0 * lon - params.eqTime + offsetMinutes
        let riseMinutes = noonMinutes - 4.0 * hourAngle
        let setMinutes = noonMinutes + 4.0 * hourAngle
        return (dayStart.addingTimeInterval(riseMinutes * 60),
                dayStart.addingTimeInterval(setMinutes * 60))
    }

    // MARK: - 月亮

    private func moonPosition(_ jd: Double) -> (ra: Double, dec: Double, distance: Double) {
        let d = jd - 2_451_545.0
        let l = rad * (218.316 + 13.176396 * d)
        let m = rad * (134.963 + 13.064993 * d)
        let f = rad * (93.272 + 13.229350 * d)
        let lonEcl = l + rad * 6.289 * sin(m)
        let latEcl = rad * 5.128 * sin(f)
        let distance = 385_001 - 20_905 * cos(m)
        let e = rad * 23.4397
        let ra = atan2(sin(lonEcl) * cos(e) - tan(latEcl) * sin(e), cos(lonEcl))
        let dec = asin(sin(latEcl) * cos(e) + cos(latEcl) * sin(e) * sin(lonEcl))
        return (ra, dec, distance)
    }

    private func moonAltitude(_ date: Date, lat: Double, lon: Double) -> Double {
        let jd = julianDay(date)
        let pos = moonPosition(jd)
        let d = jd - 2_451_545.0
        let sidereal = rad * (280.16 + 360.9856235 * d)
        let h = sidereal + lon * rad - pos.ra
        let latRad = lat * rad
        return asin(sin(latRad) * sin(pos.dec) + cos(latRad) * cos(pos.dec) * cos(h)) / rad
    }

    private func moonRiseSet(wallDayStart: Date, lat: Double, lon: Double, offsetMinutes: Double) -> (rise: Date?, set: Date?) {
        // 先把当地墙钟 0 点转成真实 UTC 时刻去采样地平高度，再把事件转回墙钟容器
        let realDayStart = wallDayStart.addingTimeInterval(-offsetMinutes * 60)
        var previous = moonAltitude(realDayStart, lat: lat, lon: lon)
        var rise: Date?
        var set: Date?
        var minute = 5.0

        while minute <= 1440 {
            let current = moonAltitude(realDayStart.addingTimeInterval(minute * 60), lat: lat, lon: lon)
            if previous < 0, current >= 0, rise == nil {
                let frac = current == previous ? 0.5 : abs(previous) / abs(current - previous)
                let realEvent = realDayStart.addingTimeInterval((minute - 5.0 + 5.0 * frac) * 60)
                rise = realEvent.addingTimeInterval(offsetMinutes * 60)
            }
            if previous >= 0, current < 0, set == nil {
                let frac = current == previous ? 0.5 : abs(previous) / abs(current - previous)
                let realEvent = realDayStart.addingTimeInterval((minute - 5.0 + 5.0 * frac) * 60)
                set = realEvent.addingTimeInterval(offsetMinutes * 60)
            }
            previous = current
            minute += 5
        }
        return (rise, set)
    }

    func moonPhase(for date: Date) -> MoonPhase {
        let jd = julianDay(date)
        let knownNewMoon = 2_451_550.1   // 2000-01-06 18:14 UTC
        var age = (jd - knownNewMoon).truncatingRemainder(dividingBy: synodicMonth)
        if age < 0 { age += synodicMonth }
        let illumination = (1 - cos(2 * .pi * age / synodicMonth)) / 2
        let distance = moonPosition(jd).distance
        return MoonPhase(age: age, illumination: illumination, distanceKm: distance)
    }
}

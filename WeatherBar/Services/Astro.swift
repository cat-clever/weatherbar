import Foundation

// MARK: - 天文计算（太阳 / 月亮 / 月相）

struct AstroCalculator {

    private let rad = Double.pi / 180
    private let synodicMonth = 29.530588853

    func compute(for date: Date, place: Place) -> AstroInfo {
        let tz = TimeZone(identifier: place.timezone ?? "") ?? .current
        let dayStart = WallClock.startOfDay(date)
        let offsetMinutes = Double(tz.secondsFromGMT(for: date)) / 60.0

        let sunrise = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                altitude: -0.833, offsetMinutes: offsetMinutes).rise
        let sunset = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                               altitude: -0.833, offsetMinutes: offsetMinutes).set

        let civil = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                              altitude: -6, offsetMinutes: offsetMinutes)
        let nautical = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                 altitude: -12, offsetMinutes: offsetMinutes)
        let astronomical = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                     altitude: -18, offsetMinutes: offsetMinutes)

        let blueMorning = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                    altitude: -6, offsetMinutes: offsetMinutes).rise
        let goldenMorning = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                      altitude: -4, offsetMinutes: offsetMinutes).rise
        let goldenEveningStart = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                           altitude: 6, offsetMinutes: offsetMinutes).set
        let blueEveningEnd = eventTime(dayStart: dayStart, lat: place.latitude, lon: place.longitude,
                                       altitude: -6, offsetMinutes: offsetMinutes).set

        let solarNoonMinutes = 720.0 - 4.0 * place.longitude - solarParams(julianDay(dayStart.addingTimeInterval(43_200))).eqTime + offsetMinutes
        let solarNoon = dayStart.addingTimeInterval(solarNoonMinutes * 60)

        let moonTimes = moonRiseSet(dayStart: dayStart, lat: place.latitude, lon: place.longitude)
        let phase = moonPhase(for: date)

        var daylight: Double?
        if let sunrise, let sunset {
            daylight = sunset.timeIntervalSince(sunrise)
        }

        var delta: Double?
        if let todaySunrise = sunrise, let todaySunset = sunset {
            let yesterday = dayStart.addingTimeInterval(-86_400)
            let yRise = eventTime(dayStart: yesterday, lat: place.latitude, lon: place.longitude,
                                  altitude: -0.833, offsetMinutes: offsetMinutes).rise
            let ySet = eventTime(dayStart: yesterday, lat: place.latitude, lon: place.longitude,
                                 altitude: -0.833, offsetMinutes: offsetMinutes).set
            if let yRise, let ySet {
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
            daylightDelta: delta
        )
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
        let eqTime = 4 * (y * sin(2 * l0 * rad)
                          - 2 * e * sin(m * rad)
                          + 4 * e * y * sin(m * rad) * cos(2 * l0 * rad)
                          - 0.5 * y * y * sin(4 * l0 * rad)
                          - 1.25 * e * e * sin(2 * m * rad))
        return (decl, eqTime)
    }

    private func eventTime(dayStart: Date,
                           lat: Double,
                           lon: Double,
                           altitude: Double,
                           offsetMinutes: Double) -> (rise: Date?, set: Date?) {
        let jd = julianDay(dayStart.addingTimeInterval(43_200))
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

    private func moonRiseSet(dayStart: Date, lat: Double, lon: Double) -> (rise: Date?, set: Date?) {
        var previous = moonAltitude(dayStart, lat: lat, lon: lon)
        var rise: Date?
        var set: Date?
        var minute = 5.0

        while minute <= 1440 {
            let current = moonAltitude(dayStart.addingTimeInterval(minute * 60), lat: lat, lon: lon)
            if previous < 0, current >= 0, rise == nil {
                rise = dayStart.addingTimeInterval((minute - 2.5) * 60)
            }
            if previous >= 0, current < 0, set == nil {
                set = dayStart.addingTimeInterval((minute - 2.5) * 60)
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

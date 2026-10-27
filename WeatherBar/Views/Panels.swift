import SwiftUI
import Charts

// MARK: - 实况区

struct CurrentHeaderView: View {
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var router: PopoverRouter

    let snapshot: WeatherSnapshot

    @State private var isHovering = false

    /// 悬停或地区列表展开时，给整块实况区描一圈系统强调色，与原版一致
    private var isHighlighted: Bool {
        isHovering || router.route == .regionSwitcher
    }

    var body: some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: Theme.headerHighlightRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.headerHighlightRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 1)
                    .padding(-Theme.headerHighlightInset)
                    .opacity(isHighlighted ? 1 : 0)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Formatters.temperature(snapshot.current.temperature, unit: prefs.temperatureUnit))
                    .font(.system(size: 68, weight: .thin))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                regionButton

                VStack(alignment: .leading, spacing: 3) {
                    statLine("风", "\(Formatters.wind(snapshot.current.windSpeed, unit: prefs.windUnit)) \(Formatters.windDirectionArrow(snapshot.current.windDirection))")
                    statLine("露点温度", Formatters.temperature(snapshot.current.dewPoint, unit: prefs.temperatureUnit))
                    statLine("气压", Formatters.pressure(snapshot.current.pressureHPa, unit: prefs.pressureUnit))
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: snapshot.current.code.symbolName(isDay: snapshot.current.isDay))
                    .font(.system(size: 38))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Theme.accentSun, Color.white)
                    .padding(.bottom, 2)

                statLine("体感温度", Formatters.temperature(snapshot.current.apparentTemperature, unit: prefs.temperatureUnit))
                statLine("紫外线指数", "\(Int(snapshot.current.uvIndex.rounded()))")
                statLine("湿度", "\(snapshot.current.humidity)%")
                statLine("能见度", Formatters.visibility(snapshot.current.visibilityMeters))
            }
            .frame(width: 150)
        }
    }

    private var regionButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                router.route = (router.route == .regionSwitcher) ? .main : .regionSwitcher
            }
        } label: {
            HStack(spacing: 4) {
                Text(places.active?.displayName ?? "未知地区")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(router.route == .regionSwitcher ? 180 : 0))
            }
            .foregroundStyle(Theme.textPrimary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击切换地区")
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - 逐小时

struct HourlyStripView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    let hours: [HourPoint]
    let now: Date

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(hours.prefix(24).enumerated()), id: \.element.id) { item in
                    let index = item.offset
                    let hour = item.element
                    VStack(spacing: 6) {
                        Text(Formatters.hourLabel(hour.date))
                            .font(.system(size: 12.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)

                        Image(systemName: hour.code.symbolName(isDay: isDay(hour.date)))
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.accentSun, Color.white)
                            .frame(height: 22)

                        Text(Formatters.temperatureShort(hour.temperature, unit: prefs.temperatureUnit))
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)

                        Capsule()
                            .fill(index == 0 ? Theme.accentBlue.opacity(0.6) : Color.clear)
                            .frame(width: 18, height: 3)
                    }
                    .frame(width: 44)
                    .contentShape(Rectangle())
                    .help("风速：\(Formatters.wind(hour.windSpeed, unit: prefs.windUnit)) · 湿度：\(hour.humidity)%")
                }
            }
            .padding(.horizontal, 2)
        }
        .card()
    }

    private func isDay(_ date: Date) -> Bool {
        let hour = WallClock.hour(of: date)
        return hour >= 6 && hour < 18
    }
}

// MARK: - 逐日

struct DailyListView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    let days: [DayPoint]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(days.prefix(7).enumerated()), id: \.element.id) { item in
                let index = item.offset
                let day = item.element
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: day.code.symbolName(isDay: true))
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.accentSun, Color.white)
                            .frame(width: 20)

                        Text(Formatters.weekday(day.date, index: index))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if day.precipitationChance >= 20 {
                            Text("\(day.precipitationChance)%")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.accentPrecip)
                        }

                        Spacer(minLength: 4)

                        Text(Formatters.temperatureShort(day.minTemperature, unit: prefs.temperatureUnit))
                            .font(.system(size: 13.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                        Text(Formatters.temperatureShort(day.maxTemperature, unit: prefs.temperatureUnit))
                            .font(.system(size: 13.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                    }

                    Text(WeatherCodeMapper.summary(code: day.code,
                                                   windMax: day.windMax,
                                                   gustMax: day.gustMax))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card(raised: index == 0)
                .contentShape(Rectangle())
                .help("最高风速：\(Formatters.wind(day.windMax, unit: prefs.windUnit)) · 阵风：\(Formatters.wind(day.gustMax, unit: prefs.windUnit))")
            }
        }
    }
}

// MARK: - 太阳与月亮

struct SunMoonPanel: View {
    @EnvironmentObject private var prefs: PreferencesStore
    let astro: AstroInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("太阳与月亮")

            HStack(spacing: 0) {
                timeCell(icon: "sunrise.fill", label: "日出", value: Formatters.clockLabel(astro.sunrise))
                timeCell(icon: "sun.max.fill", label: "正午", value: Formatters.clockLabel(astro.solarNoon))
                timeCell(icon: "sunset.fill", label: "日落", value: Formatters.clockLabel(astro.sunset))
            }

            HStack(spacing: 0) {
                timeCell(icon: "moonrise.fill", label: "月出", value: Formatters.clockLabel(astro.moonrise))
                timeCell(icon: "moonset.fill", label: "月落", value: Formatters.clockLabel(astro.moonset))
            }

            if let daylight = astro.daylightSeconds {
                HStack(spacing: 6) {
                    Text(Formatters.duration(daylight) + " 的日光")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    if let delta = astro.daylightDelta {
                        Text(Formatters.signedMinutes(delta))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
            }

            Divider().overlay(Theme.cardStroke)

            VStack(spacing: 3) {
                twilightRow("民用", astro.civilDawn, astro.civilDusk)
                twilightRow("航海", astro.nauticalDawn, astro.nauticalDusk)
                twilightRow("天文", astro.astronomicalDawn, astro.astronomicalDusk)
            }

            Divider().overlay(Theme.cardStroke)

            VStack(spacing: 3) {
                magicRow("蓝色时光", astro.blueHourMorning, Theme.accentBlue)
                magicRow("黄金时光", astro.goldenHourMorning, Theme.accentSun)
                magicRow("黄金时光", astro.goldenHourEvening, Theme.accentSun)
                magicRow("蓝色时光", astro.blueHourEvening, Theme.accentBlue)
            }
        }
        .card()
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accentBlue)
    }

    private func timeCell(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func twilightRow(_ label: String, _ dawn: Date?, _ dusk: Date?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textTertiary)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(Formatters.clockLabel(dawn))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
            Text("→")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text(Formatters.clockLabel(dusk))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private func magicRow(_ label: String, _ date: Date?, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(Formatters.clockLabel(date))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - 曲线

struct TrendChartsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    let hours: [HourPoint]

    var body: some View {
        VStack(spacing: 10) {
            windChart
            humidityChart
        }
    }

    private var windChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windHeadline)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("风速")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Chart(hours) { hour in
                LineMark(
                    x: .value("时间", hour.date),
                    y: .value("风速", hour.windSpeed)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.chartLine)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                PointMark(
                    x: .value("时间", hour.date),
                    y: .value("风速", hour.windSpeed)
                )
                .symbol(.diamond)
                .symbolSize(12)
                .foregroundStyle(Theme.chartLine)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 80)
        }
        .card()
    }

    private var humidityChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(hours.first?.humidity ?? 0)%")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("湿度")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Chart(hours) { hour in
                AreaMark(
                    x: .value("时间", hour.date),
                    y: .value("湿度", hour.humidity)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(colors: [Theme.chartFillTop, Theme.chartFillBottom],
                                   startPoint: .top, endPoint: .bottom)
                )
                LineMark(
                    x: .value("时间", hour.date),
                    y: .value("湿度", hour.humidity)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.chartLine)
                .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...100)
            .frame(height: 80)

            Text("\(hours.last?.humidity ?? 0)%")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .card()
    }

    private var windHeadline: String {
        guard let first = hours.first, let last = hours.last else { return "—" }
        let unit = prefs.windUnit
        return "\(Formatters.windShort(first.windSpeed, unit: unit)) → \(Formatters.windShort(last.windSpeed, unit: unit)) \(unit.shortLabel)"
    }
}

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
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CardFramesKey.self,
                        value: [-1: proxy.frame(in: .named("panel"))]
                    )
                }
            )
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
                // 悬停实况区时展开左侧详情栏；离开这块卡片就收起
                if hovering {
                    if !router.expanded {
                        withAnimation(.easeOut(duration: 0.16)) {
                            router.expanded = true
                        }
                    }
                    router.expand()
                } else {
                    router.scheduleCollapse()
                }
            }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Formatters.temperature(snapshot.current.temperature, unit: prefs.temperatureUnit, decimals: 1))
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
    @EnvironmentObject private var router: PopoverRouter
    let hours: [HourPoint]
    let now: Date

    private let cellWidth: CGFloat = 44

    var body: some View {
        HorizontalWheelScroll(contentWidth: CGFloat(hours.prefix(24).count) * cellWidth + 4) {
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
                    .frame(width: cellWidth)
                    .contentShape(Rectangle())
                    .help("风速：\(Formatters.wind(hour.windSpeed, unit: prefs.windUnit)) · 湿度：\(hour.humidity)%")
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 84)
        .card()
    }

    private func isDay(_ date: Date) -> Bool {
        let hour = WallClock.hour(of: date)
        return hour >= 6 && hour < 18
    }
}

// MARK: - 逐日

/// 收集各卡片（实况区 -1、逐日横条 0…）在面板内的矩形，供浮窗定位与「是否还在当前卡片」判断
struct CardFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct DailyListView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var router: PopoverRouter
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
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CardFramesKey.self,
                            value: [index: proxy.frame(in: .named("panel"))]
                        )
                    }
                )
                .card(raised: index == 0)
                .hoverHighlight()
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        router.hoveredDay = index
                        router.expand()
                    } else if router.hoveredDay == index {
                        router.scheduleCollapse()
                    }
                }
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
            PanelTitle("太阳与月亮")

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
        }
        .card()
        .hoverHighlight()
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
}

// MARK: - 黎明

struct TwilightPanel: View {
    let astro: AstroInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PanelTitle("黎明")

            VStack(spacing: 5) {
                twilightRow("民用", icon: "person.fill", astro.civilDawn, astro.civilDusk)
                twilightRow("航海", icon: "sailboat.fill", astro.nauticalDawn, astro.nauticalDusk)
                twilightRow("天文", icon: "globe.asia.australia.fill", astro.astronomicalDawn, astro.astronomicalDusk)
            }
        }
        .card()
        .hoverHighlight()
    }

    private func twilightRow(_ label: String, icon: String, _ dawn: Date?, _ dusk: Date?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                Text(Formatters.clockLabel(dawn))
                Text(Formatters.clockLabel(dusk))
            }
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - 魔法时光

struct MagicHourPanel: View {
    let astro: AstroInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PanelTitle("魔法时光")

            VStack(spacing: 5) {
                magicRow("蓝色时光", icon: "clock.fill", astro.blueHourMorning, Theme.accentBlue)
                magicRow("黄金时光", icon: "clock.fill", astro.goldenHourMorning, Theme.accentSun)
                magicRow("黄金时光", icon: "clock.fill", astro.goldenHourEvening, Theme.accentSun)
                magicRow("蓝色时光", icon: "clock.fill", astro.blueHourEvening, Theme.accentBlue)
            }
        }
        .card()
        .hoverHighlight()
    }

    private func magicRow(_ label: String, icon: String, _ date: Date?, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 6)
            Text(Formatters.clockLabel(date))
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// 卡片蓝色小标题
struct PanelTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accentBlue)
    }
}

// MARK: - 曲线

/// 曲线可切换的指标
enum TrendMetric: String, CaseIterable, Identifiable {
    case wind, humidity, pressure, dewPoint, uv, apparent, precipitation, cloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wind: return "风速"
        case .humidity: return "湿度"
        case .pressure: return "气压"
        case .dewPoint: return "露点温度"
        case .uv: return "紫外线指数"
        case .apparent: return "体感温度"
        case .precipitation: return "降水"
        case .cloud: return "云量"
        }
    }

    var domain: ClosedRange<Double>? {
        switch self {
        case .humidity, .cloud: return 0...100
        default: return nil
        }
    }

    var isFilled: Bool {
        switch self {
        case .humidity, .cloud, .precipitation: return true
        default: return false
        }
    }

    func value(_ hour: HourPoint) -> Double? {
        switch self {
        case .wind: return hour.windSpeed
        case .humidity: return Double(hour.humidity)
        case .pressure: return hour.pressureHPa
        case .dewPoint: return hour.dewPoint
        case .uv: return hour.uvIndex
        case .apparent: return hour.apparentTemperature
        case .precipitation: return hour.precipitation
        case .cloud: return hour.cloudCover.map(Double.init)
        }
    }

    func formatted(_ value: Double,
                   temperatureUnit: TemperatureUnit,
                   windUnit: WindUnit,
                   pressureUnit: PressureUnit) -> String {
        switch self {
        case .wind:
            return "\(Formatters.windShort(value, unit: windUnit)) \(windUnit.shortLabel)"
        case .humidity, .cloud:
            return "\(Int(value.rounded()))%"
        case .pressure:
            return Formatters.pressure(value, unit: pressureUnit)
        case .dewPoint, .apparent:
            return Formatters.temperature(value, unit: temperatureUnit)
        case .uv:
            return "\(Int(value.rounded()))"
        case .precipitation:
            return String(format: "%.1f 毫米", value)
        }
    }
}

struct TrendChartsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    let hours: [HourPoint]

    @State private var primary: TrendMetric = .wind
    @State private var secondary: TrendMetric = .humidity

    var body: some View {
        VStack(spacing: 10) {
            chart(selection: $primary)
            chart(selection: $secondary)
        }
    }

    private struct TrendPoint: Identifiable {
        let id: Date
        let value: Double
    }

    private func points(for metric: TrendMetric) -> [TrendPoint] {
        hours.compactMap { hour in
            guard let value = metric.value(hour) else { return nil }
            return TrendPoint(id: hour.date, value: value)
        }
    }

    private func chart(selection: Binding<TrendMetric>) -> some View {
        let metric = selection.wrappedValue
        let data = points(for: metric)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(headline(metric, data: data))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 6)

                // 点这里也能切换指标（右键菜单同样可用）
                Menu {
                    metricMenu(selection: selection, current: metric)
                } label: {
                    HStack(spacing: 4) {
                        Text(metric.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if data.isEmpty {
                Text("暂无数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if let domain = metric.domain {
                plot(metric, data: data)
                    .chartYScale(domain: domain)
            } else {
                plot(metric, data: data)
            }
        }
        .card()
        .hoverHighlight()
        .contextMenu {
            metricMenu(selection: selection, current: metric)
        }
    }

    @ViewBuilder
    private func metricMenu(selection: Binding<TrendMetric>, current: TrendMetric) -> some View {
        ForEach(TrendMetric.allCases) { item in
            Button {
                selection.wrappedValue = item
            } label: {
                if item == current {
                    Label(item.label, systemImage: "checkmark")
                } else {
                    Text(item.label)
                }
            }
        }
    }

    private func plot(_ metric: TrendMetric, data: [TrendPoint]) -> some View {
        Chart(data) { point in
            if metric.isFilled {
                AreaMark(
                    x: .value("时间", point.id),
                    y: .value(metric.label, point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(colors: [Theme.chartFillTop, Theme.chartFillBottom],
                                   startPoint: .top, endPoint: .bottom)
                )
            }

            LineMark(
                x: .value("时间", point.id),
                y: .value(metric.label, point.value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(Theme.chartLine)
            .lineStyle(StrokeStyle(lineWidth: metric == .wind ? 1.2 : 1))

            if metric == .wind {
                PointMark(
                    x: .value("时间", point.id),
                    y: .value(metric.label, point.value)
                )
                .symbol(.diamond)
                .symbolSize(12)
                .foregroundStyle(Theme.chartLine)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 80)
    }

    private func headline(_ metric: TrendMetric, data: [TrendPoint]) -> String {
        guard let first = data.first, let last = data.last else { return "—" }
        let head = metric.formatted(first.value,
                                    temperatureUnit: prefs.temperatureUnit,
                                    windUnit: prefs.windUnit,
                                    pressureUnit: prefs.pressureUnit)
        let tail = metric.formatted(last.value,
                                    temperatureUnit: prefs.temperatureUnit,
                                    windUnit: prefs.windUnit,
                                    pressureUnit: prefs.pressureUnit)
        return "\(head) → \(tail)"
    }
}

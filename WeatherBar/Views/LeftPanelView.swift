import SwiftUI

/// 左侧独立浮窗：显示「鼠标悬停的那一天」的详情。
/// 今天额外显示日月轨迹、月相、太阳三张实时卡片。
struct LeftPanelView: View {
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var router: PopoverRouter

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)

            ScrollView {
                content
                    .padding(Theme.pagePadding)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Theme.leftPanelWidth, height: Theme.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onHover { hovering in
            // 在浮窗内保持展开；离开浮窗（且没回到卡片）就收起
            if hovering {
                router.expand()
            } else {
                router.scheduleCollapse()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = store.snapshot {
            let hoveredDay = router.hoveredDay
            let index = min(max(hoveredDay ?? 0, 0), max(snapshot.daily.count - 1, 0))
            // 只有悬停主面板（没有指定某一天）时才显示日月轨迹/月相/太阳；
            // 悬停任何一条逐日横条（含今天）都显示同一套当日卡片。
            let showLiveCards = hoveredDay == nil
            let day: DayPoint? = snapshot.daily.indices.contains(index) ? snapshot.daily[index] : nil
            let hours = hours(in: snapshot, for: day)
            let astro = astro(in: snapshot, for: day, isToday: index == 0)

            VStack(spacing: Theme.blockGap) {
                if showLiveCards {
                    SkyPathCard(astro: snapshot.astro, place: snapshot.place)
                    MoonDetailCard(astro: snapshot.astro)
                    SunDetailCard(astro: snapshot.astro)
                }

                if hours.isEmpty {
                    Text("该日暂无逐小时数据")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else if !showLiveCards {
                    // 悬停主面板时主面板已经有今天的逐小时，这里不重复
                    HourlyStripView(hours: hours, now: Date())
                }

                SunMoonPanel(astro: astro)
                TwilightPanel(astro: astro)
                MagicHourPanel(astro: astro)

                PrecipitationCard(chance: precipitationChance(hours: hours, day: day),
                                  amount: precipitationAmount(hours: hours))

                if !hours.isEmpty {
                    TrendChartsView(hours: hours)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    // MARK: - 按天取数

    private func hours(in snapshot: WeatherSnapshot, for day: DayPoint?) -> [HourPoint] {
        guard let day else { return snapshot.hourly }
        let start = WallClock.startOfDay(day.date)
        return snapshot.hourly.filter { WallClock.startOfDay($0.date) == start }
    }

    private func astro(in snapshot: WeatherSnapshot, for day: DayPoint?, isToday: Bool) -> AstroInfo {
        if isToday { return snapshot.astro }
        guard let day else { return snapshot.astro }
        return AstroCalculator().compute(for: day.date, place: snapshot.place)
    }

    private func precipitationChance(hours: [HourPoint], day: DayPoint?) -> Int {
        if let peak = hours.map(\.precipitationChance).max() { return peak }
        return day?.precipitationChance ?? 0
    }

    private func precipitationAmount(hours: [HourPoint]) -> Double {
        hours.reduce(0) { $0 + ($1.precipitation ?? 0) }
    }
}

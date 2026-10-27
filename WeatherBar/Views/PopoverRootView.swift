import SwiftUI

struct PopoverRootView: View {
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var router: PopoverRouter

    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 0) {
                switch router.route {
                case .regionSearch:
                    RegionSearchView()
                        .padding(Theme.pagePadding)
                case .main, .regionSwitcher, .settings:
                    mainContent
                }
            }
        }
        .frame(width: router.expanded ? Theme.panelWidthExpanded : Theme.panelWidth)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .onHover { hovering in
            // 鼠标离开整个面板后稍作延迟再收起，避免展开时浮窗位移导致抖动
            collapseTask?.cancel()
            guard !hovering else { return }
            collapseTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard !Task.isCancelled else { return }
                if router.expanded {
                    withAnimation(.easeOut(duration: 0.14)) {
                        router.expanded = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var mainContent: some View {
        ScrollView {
            HStack(alignment: .top, spacing: Theme.columnGap) {
                if router.expanded {
                    leftColumn
                        .transition(.opacity)
                }
                rightColumn
            }
            .padding(Theme.pagePadding)
        }
        .scrollIndicators(.hidden)
    }

    /// 左栏：日月轨迹、月相、太阳、降水、太阳与月亮、黎明、魔法时光（悬停展开）
    private var leftColumn: some View {
        VStack(spacing: Theme.blockGap) {
            if let snapshot = store.snapshot {
                SkyPathCard(astro: snapshot.astro, place: snapshot.place)
                MoonDetailCard(astro: snapshot.astro)
                SunDetailCard(astro: snapshot.astro)
                PrecipitationCard(current: snapshot.current, hourly: snapshot.hourly)
                SunMoonPanel(astro: snapshot.astro)
                TwilightPanel(astro: snapshot.astro)
                MagicHourPanel(astro: snapshot.astro)
            }
        }
        .frame(width: Theme.leftColumnWidth, alignment: .top)
    }

    /// 右栏：实况、逐小时、逐日、曲线
    private var rightColumn: some View {
        VStack(spacing: Theme.blockGap) {
            if let snapshot = store.snapshot {
                CurrentHeaderView(snapshot: snapshot)

                if router.route == .regionSwitcher {
                    RegionSwitcherView()
                }

                HourlyStripView(hours: snapshot.hourly, now: Date())

                DailyListView(days: snapshot.daily)

                if !snapshot.hourly.isEmpty {
                    TrendChartsView(hours: snapshot.hourly)
                }

                footer(snapshot)
            } else {
                placeholder
            }
        }
        .frame(width: Theme.rightColumnWidth, alignment: .top)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            if case .failed(let message) = store.phase {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textTertiary)
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await store.refresh(force: true) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.accentBlue)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("正在获取天气…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func footer(_ snapshot: WeatherSnapshot) -> some View {
        VStack(spacing: 4) {
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Text("更新于 \(Formatters.relativeTime(from: snapshot.fetchedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)

            Text("数据来源：\(snapshot.servedBy.attribution)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

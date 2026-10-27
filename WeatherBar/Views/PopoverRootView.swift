import SwiftUI

struct PopoverRootView: View {
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var router: PopoverRouter

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
        .frame(width: Theme.panelWidth)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .onHover { hovering in
            if hovering {
                router.expand()
            } else {
                router.scheduleCollapse()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var mainContent: some View {
        ScrollView {
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
            .padding(Theme.pagePadding)
        }
        .scrollIndicators(.hidden)
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

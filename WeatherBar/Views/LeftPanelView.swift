import SwiftUI

/// 左侧独立浮窗的内容：日月轨迹、月相、太阳、降水、太阳与月亮、黎明、魔法时光
struct LeftPanelView: View {
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var router: PopoverRouter

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom],
                           startPoint: .top, endPoint: .bottom)

            ScrollView {
                VStack(spacing: Theme.blockGap) {
                    if let snapshot = store.snapshot {
                        SkyPathCard(astro: snapshot.astro, place: snapshot.place)
                        MoonDetailCard(astro: snapshot.astro)
                        SunDetailCard(astro: snapshot.astro)
                        PrecipitationCard(current: snapshot.current, hourly: snapshot.hourly)
                        SunMoonPanel(astro: snapshot.astro)
                        TwilightPanel(astro: snapshot.astro)
                        MagicHourPanel(astro: snapshot.astro)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(Theme.pagePadding)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: Theme.leftPanelWidth, height: Theme.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onHover { hovering in
            if hovering {
                router.expand()
            } else {
                router.scheduleCollapse()
            }
        }
    }
}

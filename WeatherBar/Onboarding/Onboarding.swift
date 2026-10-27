import AppKit
import SwiftUI

// MARK: - 首次引导

@MainActor
final class OnboardingController {
    private var panel: NSPanel?
    private let anchor: () -> NSStatusBarButton?
    private let places: PlaceStore
    private let store: WeatherStore
    private let onFinish: () -> Void

    init(anchor: @escaping () -> NSStatusBarButton?,
         places: PlaceStore,
         store: WeatherStore,
         onFinish: @escaping () -> Void) {
        self.anchor = anchor
        self.places = places
        self.store = store
        self.onFinish = onFinish
    }

    static var hasCompleted: Bool {
        UserDefaults.standard.integer(forKey: "onboarding.version") >= 1
    }

    func showIfNeeded() {
        guard !Self.hasCompleted else { return }
        show()
    }

    func show() {
        guard panel == nil,
              let button = anchor(),
              let hostWindow = button.window else { return }

        let rectOnScreen = hostWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let width: CGFloat = 320

        let content = OnboardingView(
            places: places,
            store: store,
            onFinish: { [weak self] in self?.dismiss() },
            onSkip: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let height = max(fitting.height, 150)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.isMovable = false

        let screen = NSScreen.screens.first { $0.frame.contains(rectOnScreen) } ?? NSScreen.main
        var x = rectOnScreen.midX - width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        }
        let y = rectOnScreen.minY - height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        UserDefaults.standard.set(1, forKey: "onboarding.version")
        UserDefaults.standard.set(true, forKey: "onboarding.completed")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.panel = nil
            self?.onFinish()
        }
    }
}

// MARK: - 引导内容

struct OnboardingView: View {
    @ObservedObject var places: PlaceStore
    @ObservedObject var store: WeatherStore
    let onFinish: () -> Void
    let onSkip: () -> Void

    @State private var step = 0
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searchTask: Task<Void, Never>?

    private let pages: [(title: String, body: String)] = [
        ("我在这里 👋", "天气常驻在菜单栏右上角，随时瞄一眼。"),
        ("点一下看详情", "单击图标展开完整天气；右键有刷新、地区、设置。"),
        ("先选你的地区", "告诉我在哪，我才能报准天气。也可以直接用当前位置。")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pages[step].title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(pages[step].body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: onSkip) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            if step == 2 {
                searchSection
            }

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Theme.accentBlue : Color.white.opacity(0.25))
                            .frame(width: 6, height: 6)
                            .onTapGesture { step = index }
                    }
                }
                Spacer()
                Button(step == 2 ? "完成" : "下一步") {
                    if step == 2 { onFinish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.accentBlue)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.onboardingBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("搜索城市，如 上海 / Tokyo", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: query) { newValue in
                    scheduleSearch(newValue)
                }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results.prefix(4)) { place in
                        Button {
                            places.add(place)
                            Task { await store.refresh(force: true) }
                            onFinish()
                        } label: {
                            HStack {
                                Text(place.displayName)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(place.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                Task {
                    if let place = try? await store.locator.requestPlace() {
                        places.updateCurrentLocation(place)
                        places.setActive(places.places.first(where: { $0.isCurrentLocation })?.id ?? place.id)
                        await store.refresh(force: true)
                        onFinish()
                    }
                }
            } label: {
                Label("使用当前位置", systemImage: "location.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accentBlue)
            }
            .buttonStyle(.plain)
        }
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        guard text.trimmingCharacters(in: .whitespaces).count >= 1 else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = (try? await GeocodingService.shared.search(text)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { results = found }
        }
    }
}

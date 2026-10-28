import AppKit
import SwiftUI

// MARK: - 首次引导

@MainActor
final class OnboardingController {
    private var panel: OnboardingPanel?
    private var hosting: NSHostingView<OnboardingView>?
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
            onSkip: { [weak self] in self?.dismiss() },
            onLayoutChange: { [weak self] in self?.resizePanel() }
        )

        let hosting = NSHostingView(rootView: content)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let height = max(fitting.height, 150)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = OnboardingPanel(
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
        // 需要能接收键盘输入（搜索框）
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        self.hosting = hosting
    }

    /// 内容变高（切到第 3 步、搜索出结果）时把面板拉长，顶边保持不动
    private func resizePanel() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let newHeight = max(hosting.fittingSize.height, 150)
        let old = panel.frame
        guard abs(old.height - newHeight) > 0.5 else { return }
        let newOrigin = NSPoint(x: old.minX, y: old.minY + (old.height - newHeight))
        panel.setFrame(NSRect(origin: newOrigin, size: NSSize(width: old.width, height: newHeight)),
                       display: true)
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
            self?.hosting = nil
            self?.onFinish()
        }
    }
}

/// 允许成为 key window，否则搜索框收不到键盘输入
final class OnboardingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 引导内容

struct OnboardingView: View {
    @ObservedObject var places: PlaceStore
    @ObservedObject var store: WeatherStore
    let onFinish: () -> Void
    let onSkip: () -> Void
    /// 内容高度变化时通知外部调整面板大小
    var onLayoutChange: (() -> Void)? = nil

    @State private var step = 0
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searchedText = ""
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
        .onChange(of: step) { _ in onLayoutChange?() }
        .onChange(of: results.count) { _ in onLayoutChange?() }
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
                            HStack(spacing: 6) {
                                Text(place.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 4)
                                Text(place.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            } else if searchedText != "" {
                Text("没有找到「\(searchedText)」")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 2)
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
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            searchedText = ""
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = (try? await GeocodingService.shared.search(text)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                results = found
                searchedText = trimmed
            }
        }
    }
}

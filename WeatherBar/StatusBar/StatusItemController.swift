// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import AppKit
import SwiftUI
import Combine

// MARK: - 面板路由

enum PopoverRoute: Equatable {
    case main
    case regionSwitcher
    case regionSearch
    case settings
}

@MainActor
final class PopoverRouter: ObservableObject {
    @Published var route: PopoverRoute = .main
    /// 鼠标悬停实况区时，在左侧弹出独立的详情浮窗
    @Published var expanded = false
    /// 浮窗当前显示第几天的详情（nil = 今天）
    @Published var hoveredDay: Int?
    /// 各卡片在面板内的矩形：-1 = 实况区，0… = 逐日横条
    @Published var cardFrames: [Int: CGRect] = [:]
    var onOpenSettings: (() -> Void)?

    /// 浮窗顶部相对主面板顶部的偏移
    var anchorTop: CGFloat {
        guard let day = hoveredDay, let frame = cardFrames[day] else { return 0 }
        return frame.minY
    }

    private var collapseTask: Task<Void, Never>?

    func reset() {
        route = .main
        collapseNow()
    }

    func openSettings() { onOpenSettings?() }

    /// 立即展开（或保持展开）
    func expand() {
        collapseTask?.cancel()
        collapseTask = nil
        if !expanded { expanded = true }
    }

    /// 延迟收起：给鼠标从面板移到左浮窗留出时间
    func scheduleCollapse(after nanoseconds: UInt64 = 220_000_000) {
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.expanded = false
            self?.hoveredDay = nil
        }
    }

    func collapseNow() {
        collapseTask?.cancel()
        collapseTask = nil
        if expanded { expanded = false }
        hoveredDay = nil
    }
}

// MARK: - 状态栏控制器

@MainActor
final class StatusItemController: NSObject {
    private let store: WeatherStore
    private let places: PlaceStore
    private let prefs: PreferencesStore
    private let router: PopoverRouter
    private let settingsWindow: SettingsWindowController

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let leftPanel = LeftPanelController()
    private var cancellables = Set<AnyCancellable>()
    private var closeObserver: NSObjectProtocol?

    var onShowOnboarding: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    init(store: WeatherStore, places: PlaceStore, prefs: PreferencesStore,
         router: PopoverRouter, settingsWindow: SettingsWindowController) {
        self.store = store
        self.places = places
        self.prefs = prefs
        self.router = router
        self.settingsWindow = settingsWindow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        router.onOpenSettings = { [weak self] in self?.openSettingsWindow() }
    }

    var statusButton: NSStatusBarButton? { statusItem.button }

    func install() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        popover.behavior = .transient
        popover.animates = true

        observe()
        render()
    }

    private func observe() {
        store.$displayState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)

        // 悬停展开时在面板左侧弹出独立浮窗；切换悬停日期时只挪位置
        router.$expanded
            .combineLatest(router.$hoveredDay)
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded, _ in
                self?.updateLeftPanel(expanded: expanded)
            }
            .store(in: &cancellables)

        // 卡片矩形测量完成后重新摆一次位置
        router.$cardFrames
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.router.expanded else { return }
                self.updateLeftPanel(expanded: true)
            }
            .store(in: &cancellables)

        // 面板关闭时收起左浮窗（点别处关掉 popover 的情况）
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.leftPanel.hide()
                self?.router.collapseNow()
            }
        }
    }

    private func updateLeftPanel(expanded: Bool) {
        guard expanded,
              popover.isShown,
              let parent = popover.contentViewController?.view.window,
              let anchorRect = mainPanelScreenRect(in: parent) else {
            leftPanel.hide()
            return
        }

        if leftPanel.isVisible {
            leftPanel.reposition(beside: parent, anchorRect: anchorRect, anchorTop: router.anchorTop)
            return
        }

        leftPanel.show(
            beside: parent,
            anchorRect: anchorRect,
            anchorTop: router.anchorTop,
            content: LeftPanelView()
                .environmentObject(store)
                .environmentObject(places)
                .environmentObject(prefs)
                .environmentObject(router)
        )
    }

    /// 主面板内容视图在屏幕坐标系里的真实矩形（不含 popover 窗口的透明边距）
    private func mainPanelScreenRect(in window: NSWindow) -> NSRect? {
        guard let view = popover.contentViewController?.view else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: 渲染

    /// 按天气类型给状态栏图标上色（调色板按图层顺序对应 SF Symbol 的各层）
    private static func palette(for symbol: String) -> [NSColor] {
        if symbol.contains("bolt") {
            return [.labelColor, .systemYellow]
        }
        if symbol.contains("snow") || symbol.contains("sleet") {
            return [.labelColor, .systemTeal]
        }
        if symbol.contains("rain") || symbol.contains("drizzle") {
            return [.labelColor, .systemBlue]
        }
        if symbol.contains("fog") {
            return [.secondaryLabelColor, .labelColor]
        }
        if symbol.contains("cloud") && symbol.contains("sun") {
            return [.labelColor, .systemYellow]
        }
        if symbol.contains("cloud") && symbol.contains("moon") {
            return [.labelColor, .systemIndigo]
        }
        if symbol.contains("moon") {
            return [.systemIndigo, .labelColor]
        }
        if symbol.contains("sun") {
            return [.systemYellow, .labelColor]
        }
        return [.labelColor, .secondaryLabelColor]
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let state = store.displayState
        let style = prefs.statusBarStyle

        // 彩色渲染：太阳黄、雨蓝、云用自适应文字色（浅色/深色菜单栏都看得见）
        let base = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let palette = NSImage.SymbolConfiguration(paletteColors: Self.palette(for: state.symbolName))
        let image = NSImage(systemSymbolName: state.symbolName,
                            accessibilityDescription: state.symbolDescription)?
            .withSymbolConfiguration(base.applying(palette))
        image?.isTemplate = false

        switch style {
        case .both:
            button.image = image
            button.attributedTitle = attributed(state.temperatureText)
        case .iconOnly:
            button.image = image
            button.attributedTitle = NSAttributedString(string: "")
        case .temperatureOnly:
            button.image = nil
            button.attributedTitle = attributed(state.temperatureText)
        }

        button.appearsDisabled = state.isStale
        button.toolTip = "\(store.currentPlace.displayName) · \(state.symbolDescription) \(state.temperatureText)"
    }

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: " " + text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )
    }

    // MARK: 交互

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        router.reset()

        let root = PopoverRootView()
            .environmentObject(store)
            .environmentObject(places)
            .environmentObject(prefs)
            .environmentObject(router)

        let controller = NSHostingController(rootView: root)
        controller.view.frame.size = NSSize(width: Theme.panelWidth, height: Theme.panelHeight)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: Theme.panelWidth, height: Theme.panelHeight)
        controller.view.layoutSubtreeIfNeeded()
        disableScrollIndicators(in: controller.view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "刷新", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(.separator())

        let regionItem = NSMenuItem(title: "地区", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for place in places.places {
            let item = NSMenuItem(title: place.displayName, action: #selector(selectPlace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = place.id.uuidString
            item.state = place.id == places.activeID ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let manage = NSMenuItem(title: "管理地区…", action: #selector(openSettings), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)
        regionItem.submenu = submenu
        menu.addItem(regionItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self

        let loginItem = NSMenuItem(title: "开机启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = prefs.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(withTitle: "显示引导", action: #selector(showOnboarding), keyEquivalent: "").target = self
        menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 WeatherBar", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        Task { await store.refresh(force: true) }
    }

    @objc private func selectPlace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        places.setActive(id)
        Task { await store.refresh(force: true) }
    }

    @objc private func toggleLaunchAtLogin() {
        prefs.launchAtLogin.toggle()
    }

    @objc private func showOnboarding() {
        onShowOnboarding?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func openSettings() {
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

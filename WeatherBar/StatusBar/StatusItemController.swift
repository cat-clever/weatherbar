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
    var onOpenSettings: (() -> Void)?

    func reset() { route = .main }
    func openSettings() { onOpenSettings?() }
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
    private var cancellables = Set<AnyCancellable>()

    var onShowOnboarding: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    init(store: WeatherStore, places: PlaceStore, prefs: PreferencesStore,
         router: PopoverRouter, settingsWindow: SettingsWindowController) {
        self.store = store
        self.places = places
        self.prefs = prefs
        self.router = router
        self.settingsWindow = settingsWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
    }

    // MARK: 渲染

    private func render() {
        guard let button = statusItem.button else { return }
        let state = store.displayState
        let style = prefs.statusBarStyle

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(systemSymbolName: state.symbolName,
                            accessibilityDescription: state.symbolDescription)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true

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
        controller.view.frame.size = NSSize(width: Theme.panelWidth, height: 640)
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: Theme.panelWidth, height: 640)
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

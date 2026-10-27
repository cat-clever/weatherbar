import SwiftUI
import AppKit

// MARK: - 应用环境

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let prefs = PreferencesStore()
    let places = PlaceStore()
    let router = PopoverRouter()

    private(set) lazy var store = WeatherStore(prefs: prefs, places: places)
    private(set) lazy var updater = AppUpdater()
    private(set) lazy var settingsWindowController = SettingsWindowController(
        prefs: prefs, places: places, store: store
    )

    private(set) lazy var statusController: StatusItemController = {
        StatusItemController(
            store: store, places: places, prefs: prefs,
            router: router, settingsWindow: settingsWindowController
        )
    }()

    private(set) lazy var onboarding: OnboardingController = {
        OnboardingController(
            anchor: { [weak self] in self?.statusController.statusButton },
            places: places,
            store: store,
            onFinish: { [weak self] in self?.statusController.showPopover() }
        )
    }()

    private var scheduler: RefreshScheduler?
    private var cancellables: [NSObjectProtocol] = []

    private init() {}

    func start() {
        _ = updater
        statusController.install()
        statusController.onShowOnboarding = { [weak self] in
            self?.onboarding.show()
        }

        scheduler = RefreshScheduler(intervalMinutes: prefs.refreshMinutes) { [weak self] in
            await self?.store.refresh(force: true)
        }
        scheduler?.start()

        let observer = NotificationCenter.default.addObserver(
            forName: .weatherBarShowOnboarding, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onboarding.show() }
        }
        cancellables.append(observer)

        Task { await store.bootstrap() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.onboarding.showIfNeeded()
        }
    }
}

// MARK: - App 入口

@main
struct WeatherBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppEnvironment.shared.prefs)
                .environmentObject(AppEnvironment.shared.places)
                .environmentObject(AppEnvironment.shared.store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppEnvironment.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.store.persistBeforeExit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

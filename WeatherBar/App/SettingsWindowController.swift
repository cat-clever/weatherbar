import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: ObservableObject {
    private let prefs: PreferencesStore
    private let places: PlaceStore
    private let store: WeatherStore
    private var window: NSWindow?

    init(prefs: PreferencesStore, places: PlaceStore, store: WeatherStore) {
        self.prefs = prefs
        self.places = places
        self.store = store
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = SettingsView()
            .environmentObject(prefs)
            .environmentObject(places)
            .environmentObject(store)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = "WeatherBar 设置"
        window.setContentSize(NSSize(width: 520, height: 460))
        window.minSize = NSSize(width: 520, height: 460)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

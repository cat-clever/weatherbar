// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: ObservableObject {
    private let prefs: PreferencesStore
    private let places: PlaceStore
    private let store: WeatherStore
    private let updater: AppUpdater
    private var window: NSWindow?

    init(prefs: PreferencesStore, places: PlaceStore, store: WeatherStore, updater: AppUpdater) {
        self.prefs = prefs
        self.places = places
        self.store = store
        self.updater = updater
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
            .environmentObject(updater)
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

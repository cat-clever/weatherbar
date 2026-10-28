// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation
import AppKit
import Security
import ServiceManagement

// MARK: - Keychain

enum KeychainKey: String, CaseIterable {
    case qweatherKey = "provider.qweather.key"
    case qweatherHost = "provider.qweather.host"
    case seniverseKey = "provider.seniverse.key"
    case amapKey = "provider.amap.key"
    case caiyunToken = "provider.caiyun.token"
    case openWeatherKey = "provider.openweather.key"
    case weatherKitCredentials = "provider.weatherkit.credentials"
}

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private let lock = NSLock()
    private var cache: [String: String]?

    // 说明：早期版本把 Key 存进系统钥匙串，但同时又往 UserDefaults 写了一份 fallback，
    // 钥匙串并没带来额外保护；而未签名分发的应用每次更新二进制指纹都变，
    // macOS 会反复弹「请输入登录钥匙串密码」。
    // 现在改为存到应用支持目录下的独立配置文件 secrets.json（权限 0600）。

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("WeatherBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }

    private func load() -> [String: String] {
        if let cache { return cache }
        var values: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            values = decoded
        }
        // 迁移：旧版本写在 UserDefaults 里的 secret.* / fallback.*
        let defaults = UserDefaults.standard
        var migrated = false
        for key in KeychainKey.allCases {
            let name = key.rawValue
            if values[name] == nil {
                if let old = defaults.string(forKey: "secret." + name) ?? defaults.string(forKey: "fallback." + name),
                   !old.isEmpty {
                    values[name] = old
                    migrated = true
                }
            }
            defaults.removeObject(forKey: "secret." + name)
            defaults.removeObject(forKey: "fallback." + name)
        }
        cache = values
        if migrated { persist(values) }
        return values
    }

    private func persist(_ values: [String: String]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func string(for key: KeychainKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[key.rawValue]
    }

    func set(_ value: String?, for key: KeychainKey) {
        lock.lock(); defer { lock.unlock() }
        var values = load()
        if let value, !value.isEmpty {
            values[key.rawValue] = value
        } else {
            values.removeValue(forKey: key.rawValue)
        }
        cache = values
        persist(values)
    }

    func hasValue(for key: KeychainKey) -> Bool {
        !(string(for: key) ?? "").isEmpty
    }
}

// MARK: - 偏好

enum StatusBarStyle: String, CaseIterable, Identifiable {
    case both, iconOnly, temperatureOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return "图标 + 温度"
        case .iconOnly: return "仅图标"
        case .temperatureOnly: return "仅温度"
        }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    @Published var temperatureUnit: TemperatureUnit { didSet { save(temperatureUnit.rawValue, "unit.temperature") } }
    @Published var windUnit: WindUnit { didSet { save(windUnit.rawValue, "unit.wind") } }
    @Published var pressureUnit: PressureUnit { didSet { save(pressureUnit.rawValue, "unit.pressure") } }
    @Published var refreshMinutes: Int { didSet { save(refreshMinutes, "refresh.minutes") } }
    @Published var providerPreference: ProviderID { didSet { save(providerPreference.rawValue, "provider.preference") } }
    @Published var statusBarStyle: StatusBarStyle { didSet { save(statusBarStyle.rawValue, "statusbar.style") } }
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: "unit.temperature") ?? "") ?? .celsius
        windUnit = WindUnit(rawValue: defaults.string(forKey: "unit.wind") ?? "") ?? .kmh
        pressureUnit = PressureUnit(rawValue: defaults.string(forKey: "unit.pressure") ?? "") ?? .hpa
        let minutes = defaults.integer(forKey: "refresh.minutes")
        refreshMinutes = minutes == 0 ? 15 : minutes
        providerPreference = ProviderID(rawValue: defaults.string(forKey: "provider.preference") ?? "") ?? .auto
        statusBarStyle = StatusBarStyle(rawValue: defaults.string(forKey: "statusbar.style") ?? "") ?? .both
        launchAtLogin = LaunchAtLoginService.isEnabled
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func applyLaunchAtLogin() {
        LaunchAtLoginService.setEnabled(launchAtLogin)
    }
}

// MARK: - 快照缓存

final class SnapshotCache {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("WeatherBar/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(provider: ProviderID, placeID: UUID) -> URL {
        directory.appendingPathComponent("\(provider.rawValue)-\(placeID.uuidString).json")
    }

    func save(_ snapshot: WeatherSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url(provider: snapshot.servedBy, placeID: snapshot.place.id), options: .atomic)
        // 同时写一份「最近」用于无参启动
        try? data.write(to: directory.appendingPathComponent("last.json"), options: .atomic)
    }

    func load(provider: ProviderID, placeID: UUID) -> WeatherSnapshot? {
        loadFile(url(provider: provider, placeID: placeID))
    }

    func loadLast() -> WeatherSnapshot? {
        loadFile(directory.appendingPathComponent("last.json"))
    }

    private func loadFile(_ url: URL) -> WeatherSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WeatherSnapshot.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

// MARK: - 开机启动

enum LaunchAtLoginService {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("WeatherBar: launch at login failed: \(error)")
        }
    }
}

// MARK: - 刷新调度

@MainActor
final class RefreshScheduler {
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let handler: () async -> Void
    private var interval: TimeInterval

    init(intervalMinutes: Int, handler: @escaping () async -> Void) {
        self.interval = TimeInterval(max(intervalMinutes, 1) * 60)
        self.handler = handler
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.handler() }
        }
        timer?.tolerance = 30

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handler() }
        })
    }

    func updateInterval(minutes: Int) {
        interval = TimeInterval(max(minutes, 1) * 60)
        if timer != nil { start() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

}

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
    private let service = "com.catclever.weatherbar"
    private let lock = NSLock()

    func string(for key: KeychainKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let value = readKeychain(key) { return value }
        // 沙盒/签名受限时的降级存储
        return UserDefaults.standard.string(forKey: "fallback." + key.rawValue)
    }

    func set(_ value: String?, for key: KeychainKey) {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            writeKeychain(value, for: key)
            UserDefaults.standard.set(value, forKey: "fallback." + key.rawValue)
        } else {
            deleteKeychain(key)
            UserDefaults.standard.removeObject(forKey: "fallback." + key.rawValue)
        }
    }

    func hasValue(for key: KeychainKey) -> Bool {
        !(string(for: key) ?? "").isEmpty
    }

    // MARK: 原始操作

    private func query(_ key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }

    private func readKeychain(_ key: KeychainKey) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func writeKeychain(_ value: String, for key: KeychainKey) -> Bool {
        let data = Data(value.utf8)
        let base = query(key)
        let status = SecItemCopyMatching(base as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func deleteKeychain(_ key: KeychainKey) {
        SecItemDelete(query(key) as CFDictionary)
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

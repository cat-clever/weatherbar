// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation

// MARK: - 提供商标识

enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case openMeteo
    case weatherKit
    case qweather
    case seniverse
    case amap
    case caiyun
    case openWeather
    case metNorway
    case sevenTimer
    case msn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .openMeteo: return "Open-Meteo"
        case .weatherKit: return "Apple Weather"
        case .qweather: return "和风天气"
        case .seniverse: return "心知天气"
        case .amap: return "高德天气"
        case .caiyun: return "彩云天气"
        case .openWeather: return "OpenWeather"
        case .metNorway: return "MET Norway"
        case .sevenTimer: return "7Timer!"
        case .msn: return "微软天气（MSN）"
        }
    }

    var attribution: String {
        switch self {
        case .auto: return ""
        case .openMeteo: return "Open-Meteo (CC BY 4.0)"
        case .weatherKit: return "Weather · Apple"
        case .qweather: return "和风天气 QWeather"
        case .seniverse: return "心知天气 Seniverse"
        case .amap: return "高德地图 AMap"
        case .caiyun: return "彩云天气 Caiyun"
        case .openWeather: return "OpenWeather"
        case .metNorway: return "MET Norway"
        case .sevenTimer: return "7Timer! · CMA"
        case .msn: return "MSN Weather · 中国天气网"
        }
    }

    /// 需要 Key 才能用
    var requiresKey: Bool {
        switch self {
        case .auto, .openMeteo, .metNorway, .sevenTimer, .msn: return false
        default: return true
        }
    }

    var isImplemented: Bool {
        switch self {
        case .auto, .openMeteo, .weatherKit, .qweather, .seniverse, .amap, .metNorway, .msn: return true
        default: return false
        }
    }
}

// MARK: - 能力位

struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let hourly = ProviderCapabilities(rawValue: 1 << 0)
    static let daily = ProviderCapabilities(rawValue: 1 << 1)
    static let alerts = ProviderCapabilities(rawValue: 1 << 2)
    static let minutely = ProviderCapabilities(rawValue: 1 << 3)
    static let airQuality = ProviderCapabilities(rawValue: 1 << 4)
    static let moonPhase = ProviderCapabilities(rawValue: 1 << 5)
}

// MARK: - 错误

enum ProviderError: LocalizedError {
    case notConfigured(String)
    case unsupported(String)
    case http(Int)
    case decoding(String)
    case network(String)
    case quota(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let name): return "\(name) 未配置 API Key"
        case .unsupported(let feature): return "当前数据源不支持 \(feature)"
        case .http(let code): return "服务器返回 HTTP \(code)"
        case .decoding: return "数据解析失败，请重试或更换数据源"
        case .network(let detail): return "网络错误：\(detail)"
        case .quota(let name): return "\(name) 额度已用尽"
        }
    }
}

// MARK: - 协议

protocol WeatherProvider: AnyObject {
    var id: ProviderID { get }
    var requiresAPIKey: Bool { get }
    var capabilities: ProviderCapabilities { get }
    var attribution: String { get }
    func isConfigured() -> Bool
    func fetch(place: Place, hours: Int, days: Int) async throws -> ProviderPayload
}

// MARK: - 熔断

final class CircuitBreaker: @unchecked Sendable {
    static let shared = CircuitBreaker()

    private let lock = NSLock()
    private var failureCounts: [ProviderID: Int] = [:]
    private var openUntil: [ProviderID: Date] = [:]
    private let threshold = 3
    private let cooldown: TimeInterval = 300

    func isOpen(_ id: ProviderID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = openUntil[id] else { return false }
        if Date() >= until {
            openUntil[id] = nil
            failureCounts[id] = 0
            return false
        }
        return true
    }

    func recordFailure(_ id: ProviderID) {
        lock.lock(); defer { lock.unlock() }
        let count = (failureCounts[id] ?? 0) + 1
        failureCounts[id] = count
        if count >= threshold {
            openUntil[id] = Date().addingTimeInterval(cooldown)
        }
    }

    func recordSuccess(_ id: ProviderID) {
        lock.lock(); defer { lock.unlock() }
        failureCounts[id] = 0
        openUntil[id] = nil
    }

    func resetAll() {
        lock.lock(); defer { lock.unlock() }
        failureCounts.removeAll()
        openUntil.removeAll()
    }
}

// MARK: - 地理围栏（决定 auto 顺序）

enum GeoFence {
    static func isMainlandChina(_ lat: Double, _ lon: Double) -> Bool {
        (18.0...53.6).contains(lat) && (73.5...135.1).contains(lon)
    }
}

// MARK: - 注册表

final class ProviderRegistry: @unchecked Sendable {
    static let shared = ProviderRegistry()

    private let lock = NSLock()
    private var providers: [ProviderID: WeatherProvider] = [:]

    func register(_ provider: WeatherProvider) {
        lock.lock(); defer { lock.unlock() }
        providers[provider.id] = provider
    }

    func provider(_ id: ProviderID) -> WeatherProvider? {
        lock.lock(); defer { lock.unlock() }
        return providers[id]
    }

    /// 用户指定源优先；auto 时按地域决定
    func chain(for place: Place, preference: ProviderID) -> [WeatherProvider] {
        lock.lock()
        let all = providers
        lock.unlock()

        var order: [ProviderID]
        if preference != .auto, all[preference] != nil {
            order = [preference] + fallbackOrder(for: place, excluding: preference)
        } else {
            order = fallbackOrder(for: place, excluding: nil)
        }

        return order.compactMap { id -> WeatherProvider? in
            guard let p = all[id], p.isConfigured(), !CircuitBreaker.shared.isOpen(id) else { return nil }
            return p
        }
    }

    private func fallbackOrder(for place: Place, excluding: ProviderID?) -> [ProviderID] {
        let inChina = GeoFence.isMainlandChina(place.latitude, place.longitude)
        let base: [ProviderID] = inChina
            ? [.qweather, .seniverse, .amap, .weatherKit, .openMeteo, .metNorway]
            : [.weatherKit, .openMeteo, .metNorway]
        return base.filter { $0 != excluding }
    }

    static func registerDefaults() {
        let registry = ProviderRegistry.shared
        registry.register(OpenMeteoProvider())
        registry.register(QWeatherProvider())
        registry.register(WeatherKitProvider())
        registry.register(SeniverseProvider())
        registry.register(AMapProvider())
        registry.register(MetNoProvider())
        registry.register(MsnWeatherProvider())
    }
}

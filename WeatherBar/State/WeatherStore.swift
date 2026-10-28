// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import Foundation
import Combine

@MainActor
final class WeatherStore: ObservableObject {
    struct DisplayState: Equatable {
        var temperatureText: String = "--°"
        var symbolName: String = "arrow.triangle.2.circlepath"
        var symbolDescription: String = "加载中"
        var isStale: Bool = false
    }

    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var displayState = DisplayState()
    @Published private(set) var servedBy: ProviderID = .openMeteo
    @Published private(set) var usingCurrentLocation = false

    let locator = LocationService()

    private let prefs: PreferencesStore
    private let places: PlaceStore
    private let cache = SnapshotCache()
    private let astro = AstroCalculator()
    private var refreshTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 30
    private var lastLocationFix: Date?
    private var lastLocationFixSucceeded = false

    init(prefs: PreferencesStore, places: PlaceStore) {
        self.prefs = prefs
        self.places = places
        ProviderRegistry.registerDefaults()
    }

    // MARK: - 生命周期

    func bootstrap() async {
        if let cached = cache.loadLast() {
            snapshot = cached
            servedBy = cached.servedBy
            applyDisplay(cached, stale: true)
            phase = .loaded
        }
        await refresh()
    }

    func refresh(force: Bool = false) async {
        refreshTask?.cancel()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRefresh(force: force)
        }
        refreshTask = task
        await task.value
    }

    // MARK: - 核心刷新

    private func performRefresh(force: Bool) async {
        if case .loading = phase, !force { return }
        phase = .loading

        let place = await resolvePlace()
        guard let place else {
            phase = .failed("没有可用地区")
            return
        }

        // 切换地区时先用该地区缓存顶上
        if snapshot?.place.id != place.id,
           let cached = cache.loadLast(),
           cached.place.id == place.id {
            snapshot = cached
            applyDisplay(cached, stale: true)
        }

        let chain = ProviderRegistry.shared.chain(for: place, preference: prefs.providerPreference)
        guard !chain.isEmpty else {
            phase = .failed("没有可用的天气数据源")
            lastError = "没有可用的天气数据源"
            return
        }

        var lastFailure: Error?
        for provider in chain {
            do {
                let payload = try await provider.fetch(place: place, hours: 24, days: 7)
                CircuitBreaker.shared.recordSuccess(provider.id)
                let info = astro.compute(for: Date(), place: place)
                let snap = WeatherSnapshot(
                    place: place,
                    fetchedAt: Date(),
                    servedBy: provider.id,
                    timezone: payload.timezone,
                    current: payload.current,
                    hourly: payload.hourly,
                    daily: payload.daily,
                    astro: info,
                    alerts: payload.alerts
                )
                cache.save(snap)
                snapshot = snap
                servedBy = provider.id
                applyDisplay(snap, stale: false)
                phase = .loaded
                lastError = nil
                retryDelay = 30
                return
            } catch {
                CircuitBreaker.shared.recordFailure(provider.id)
                lastFailure = error
            }
        }

        phase = .failed(lastFailure?.localizedDescription ?? "获取天气失败")
        lastError = lastFailure?.localizedDescription
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryDelay = min(retryDelay * 2, 600)
        let delay = retryDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.refresh(force: true)
        }
    }

    // MARK: - 地区解析

    private func resolvePlace() async -> Place? {
        if let active = places.active, active.isCurrentLocation {
            usingCurrentLocation = true

            // 定位节流：成功拿到坐标后 2 小时内不重复请求；
            // 失败则 1 分钟后重试（之前失败也按 2 小时计，导致一直用初始占位坐标）
            let interval: TimeInterval = lastLocationFixSucceeded ? 7200 : 60
            if let last = lastLocationFix, Date().timeIntervalSince(last) < interval {
                return active
            }
            do {
                let located = try await locator.requestPlace()
                lastLocationFix = Date()
                lastLocationFixSucceeded = true
                places.updateCurrentLocation(located)
                return places.active ?? located
            } catch {
                lastLocationFix = Date()
                lastLocationFixSucceeded = false
                return active
            }
        }
        usingCurrentLocation = false
        return places.active ?? Place.fallback
    }

    // MARK: - 展示状态

    private func applyDisplay(_ snap: WeatherSnapshot, stale: Bool) {
        let unit = prefs.temperatureUnit
        displayState = DisplayState(
            temperatureText: Formatters.temperatureShort(snap.current.temperature, unit: unit),
            symbolName: snap.current.code.symbolName(isDay: snap.current.isDay),
            symbolDescription: snap.current.code.localizedDescription,
            isStale: stale
        )
    }

    func refreshDisplayForUnitChange() {
        guard let snap = snapshot else { return }
        applyDisplay(snap, stale: displayState.isStale)
    }

    func persistBeforeExit() {
        if let snapshot { cache.save(snapshot) }
    }

    // MARK: - 便捷访问

    var currentPlace: Place { places.active ?? Place.fallback }

    var attribution: String {
        snapshot?.servedBy.attribution ?? servedBy.attribution
    }
}

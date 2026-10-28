import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            RegionSettingsView()
                .tabItem { Label("地区", systemImage: "mappin.and.ellipse") }
            ProviderSettingsView()
                .tabItem { Label("天气源", systemImage: "cloud") }
        }
        .frame(width: 500, height: 440)
    }
}

// MARK: - 通用

struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var store: WeatherStore
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        Form {
            Picker("温度单位", selection: $prefs.temperatureUnit) {
                ForEach(TemperatureUnit.allCases) { unit in
                    Text(unit.label).tag(unit)
                }
            }
            .onChange(of: prefs.temperatureUnit) { _ in
                store.refreshDisplayForUnitChange()
            }

            Picker("风速单位", selection: $prefs.windUnit) {
                ForEach(WindUnit.allCases) { unit in
                    Text(unit.label).tag(unit)
                }
            }

            Picker("气压单位", selection: $prefs.pressureUnit) {
                ForEach(PressureUnit.allCases) { unit in
                    Text(unit.label).tag(unit)
                }
            }

            Picker("状态栏显示", selection: $prefs.statusBarStyle) {
                ForEach(StatusBarStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }

            Picker("刷新间隔", selection: $prefs.refreshMinutes) {
                Text("5 分钟").tag(5)
                Text("15 分钟").tag(15)
                Text("30 分钟").tag(30)
                Text("60 分钟").tag(60)
            }

            Toggle("开机启动", isOn: $prefs.launchAtLogin)

            Section("软件更新") {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前版本 v\(updater.currentVersion)")
                            .font(.system(size: 13, weight: .medium))
                        Text(updater.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if updater.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button(updater.isBusy ? "更新中…" : "检查更新") {
                        updater.checkForUpdates()
                    }
                    .disabled(updater.isBusy)
                }

                Toggle("自动检查更新", isOn: Binding(
                    get: { updater.autoCheckEnabled },
                    set: { updater.setAutoCheck($0) }
                ))

                Toggle("自动下载并安装", isOn: Binding(
                    get: { updater.autoDownloadEnabled },
                    set: { updater.setAutoDownload($0) }
                ))
                .disabled(!updater.autoCheckEnabled)

                Text("更新包会直接下载并替换「应用程序」中的 WeatherBar，安装完成后自动重启，无需手动拖拽。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if updater.isRunningFromTemporaryLocation {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当前应用在临时位置运行，系统会阻止自动更新。请把它移到「应用程序」文件夹后重新打开。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button("重新播放引导") {
                    UserDefaults.standard.set(0, forKey: "onboarding.version")
                    NotificationCenter.default.post(name: .weatherBarShowOnboarding, object: nil)
                }
                Spacer()
                Button("清除缓存") {
                    SnapshotCache().clear()
                    Task { await store.refresh(force: true) }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

// MARK: - 地区

struct RegionSettingsView: View {
    @EnvironmentObject private var places: PlaceStore
    @EnvironmentObject private var store: WeatherStore
    @State private var newPlaceQuery = ""
    @State private var searchResults: [Place] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已保存地区（最多 12 个）")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            List {
                ForEach(places.places) { place in
                    HStack(spacing: 8) {
                        Image(systemName: place.isCurrentLocation ? "location.fill" : "mappin")
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.displayName)
                                .font(.system(size: 13, weight: .medium))
                            if !place.subtitle.isEmpty {
                                Text(place.subtitle)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if place.id == places.activeID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accentBlue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        places.setActive(place.id)
                        Task { await store.refresh(force: true) }
                    }
                    .contextMenu {
                        if !place.isCurrentLocation {
                            Button("删除", role: .destructive) {
                                places.remove(place.id)
                                Task { await store.refresh(force: true) }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 180)

            HStack(spacing: 6) {
                TextField("搜索城市后回车添加", text: $newPlaceQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: newPlaceQuery) { value in scheduleSearch(value) }
                    .onSubmit { addFirstResult() }

                Button("使用当前位置") {
                    Task {
                        if let place = try? await store.locator.requestPlace() {
                            places.updateCurrentLocation(place)
                            if let current = places.places.first(where: { $0.isCurrentLocation }) {
                                places.setActive(current.id)
                            }
                            await store.refresh(force: true)
                        }
                    }
                }
            }

            if !searchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(searchResults) { place in
                            Button {
                                places.add(place)
                                newPlaceQuery = ""
                                searchResults = []
                                Task { await store.refresh(force: true) }
                            } label: {
                                HStack {
                                    Text(place.displayName)
                                    Spacer()
                                    Text(place.subtitle)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(12)
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        guard text.trimmingCharacters(in: .whitespaces).count >= 1 else {
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = (try? await GeocodingService.shared.search(text)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { searchResults = found }
        }
    }

    private func addFirstResult() {
        guard let first = searchResults.first else { return }
        places.add(first)
        newPlaceQuery = ""
        searchResults = []
        Task { await store.refresh(force: true) }
    }
}

// MARK: - 天气源

struct ProviderSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var store: WeatherStore

    @State private var qweatherKey = ""
    @State private var qweatherHost = ""
    @State private var seniverseKey = ""
    @State private var amapKey = ""
    @State private var wkTeamID = ""
    @State private var wkKeyID = ""
    @State private var wkServiceID = ""
    @State private var wkPEM = ""
    @State private var testMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("提供商", selection: $prefs.providerPreference) {
                    ForEach(ProviderID.allCases.filter(\.isImplemented)) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: prefs.providerPreference) { _ in
                    Task { await store.refresh(force: true) }
                }

                Text("自动模式：中国大陆优先和风/心知/高德，海外优先 Apple Weather；全部失败时回落到 Open-Meteo，再不行用 MET Norway（免注册）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Divider()

                group(title: "和风天气", configured: KeychainStore.shared.hasValue(for: .qweatherKey)) {
                    TextField("API Host（如 abcdef.re.qweatherapi.com）", text: $qweatherHost)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key", text: $qweatherKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存") {
                            KeychainStore.shared.set(qweatherKey, for: .qweatherKey)
                            KeychainStore.shared.set(qweatherHost, for: .qweatherHost)
                            testMessage = "和风天气已保存"
                        }
                        Button("测试连接") { test(.qweather) }
                    }
                    .controlSize(.small)
                }

                group(title: "心知天气", configured: KeychainStore.shared.hasValue(for: .seniverseKey)) {
                    SecureField("API Key", text: $seniverseKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存") {
                            KeychainStore.shared.set(seniverseKey, for: .seniverseKey)
                            testMessage = "心知天气已保存"
                        }
                        Button("测试连接") { test(.seniverse) }
                    }
                    .controlSize(.small)
                }

                group(title: "高德天气", configured: KeychainStore.shared.hasValue(for: .amapKey)) {
                    SecureField("Web 服务 Key", text: $amapKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存") {
                            KeychainStore.shared.set(amapKey, for: .amapKey)
                            testMessage = "高德天气已保存"
                        }
                        Button("测试连接") { test(.amap) }
                    }
                    .controlSize(.small)
                }

                group(title: "Apple Weather（WeatherKit REST）",
                      configured: KeychainStore.shared.hasValue(for: .weatherKitCredentials)) {
                    TextField("Team ID", text: $wkTeamID).textFieldStyle(.roundedBorder)
                    TextField("Key ID", text: $wkKeyID).textFieldStyle(.roundedBorder)
                    TextField("Service ID", text: $wkServiceID).textFieldStyle(.roundedBorder)
                    SecureField("p8 私钥（-----BEGIN PRIVATE KEY-----…）", text: $wkPEM)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存") {
                            let creds = WeatherKitCredentials(teamID: wkTeamID,
                                                              keyID: wkKeyID,
                                                              serviceID: wkServiceID,
                                                              privateKeyPEM: wkPEM)
                            if let data = try? JSONEncoder().encode(creds),
                               let raw = String(data: data, encoding: .utf8) {
                                KeychainStore.shared.set(raw, for: .weatherKitCredentials)
                                testMessage = "WeatherKit 凭据已保存"
                            }
                        }
                        Button("测试连接") { test(.weatherKit) }
                    }
                    .controlSize(.small)
                }

                Text("Open-Meteo、MET Norway、7Timer 无需配置，开箱可用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let testMessage {
                    Text(testMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.accentBlue)
                }
            }
            .padding(12)
        }
    }

    private func group<Content: View>(title: String,
                                      configured: Bool,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(configured ? "已配置" : "未配置")
                    .font(.system(size: 10.5))
                    .foregroundStyle(configured ? Theme.accentBlue : Color.secondary)
            }
            content()
        }
    }

    private func test(_ id: ProviderID) {
        testMessage = "正在测试…"
        Task {
            guard let provider = ProviderRegistry.shared.provider(id) else {
                await MainActor.run { testMessage = "该数据源不可用" }
                return
            }
            do {
                let start = Date()
                _ = try await provider.fetch(place: store.currentPlace, hours: 6, days: 3)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                await MainActor.run { testMessage = "\(id.displayName) 连接成功 · \(ms) ms" }
            } catch {
                await MainActor.run { testMessage = "\(id.displayName) 失败：\(error.localizedDescription)" }
            }
        }
    }
}

extension Notification.Name {
    static let weatherBarShowOnboarding = Notification.Name("WeatherBarShowOnboarding")
}

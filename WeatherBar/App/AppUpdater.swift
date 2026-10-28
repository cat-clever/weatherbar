// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 WeatherBar contributors

import AppKit
import Combine
import Sparkle

/// 基于 Sparkle 的更新器。
///
/// 一次点击「检查更新」即可完成：查询 appcast → 下载 zip → 校验 EdDSA 签名 →
/// 就地替换「应用程序」里的 WeatherBar.app → 自动重启。
/// 写入由 Sparkle 的 InstallerLauncher 在沙盒之外完成，**不需要用户手动把 app 拖到 Applications**。
@MainActor
final class AppUpdater: NSObject, ObservableObject {

    // MARK: - 状态

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case found(version: String)
        case downloading(version: String)
        case downloaded(version: String)
        case installing(version: String)
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// 乐观初值：Sparkle 启动是异步的，先允许点击，随后由 KVO 校正。
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var autoCheckEnabled = false
    @Published private(set) var autoDownloadEnabled = false

    /// 当前版本（CFBundleShortVersionString）
    let currentVersion: String

    // Sparkle 的 delegate 只能在构造 controller 时传入，所以用 lazy 延迟到 self 可用之后
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var observations: [NSKeyValueObservation] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 生命周期

    override init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        super.init()
        configure()
    }

    private func configure() {
        let updater = controller.updater
        syncFromUpdater()

        // canCheckForUpdates / lastUpdateCheckDate 支持 KVO，用来驱动界面刷新
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] object, _ in
                let value = object.canCheckForUpdates
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] object, _ in
                let value = object.lastUpdateCheckDate
                Task { @MainActor in self?.lastCheckDate = value }
            }
        ]
    }

    private func syncFromUpdater() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        autoCheckEnabled = updater.automaticallyChecksForUpdates
        autoDownloadEnabled = updater.automaticallyDownloadsUpdates
    }

    // MARK: - 操作

    /// 手动检查更新：有新版时 Sparkle 弹窗，点「安装更新」即自动下载 + 替换 + 重启。
    func checkForUpdates() {
        guard !isBusy else { return }
        phase = .checking
        controller.updater.checkForUpdates()
    }

    func setAutoCheck(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        autoCheckEnabled = enabled
        autoDownloadEnabled = controller.updater.automaticallyDownloadsUpdates
    }

    func setAutoDownload(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        autoDownloadEnabled = enabled
    }

    // MARK: - 展示

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            if let lastCheckDate {
                return "上次检查：\(Self.dateFormatter.string(from: lastCheckDate))"
            }
            return "尚未检查更新"
        case .checking:
            return "正在检查新版本…"
        case .upToDate:
            return "当前已是最新版本"
        case .found(let version):
            return "发现新版本 v\(version)"
        case .downloading(let version):
            return "正在下载 v\(version)…"
        case .downloaded(let version):
            return "v\(version) 已就绪，退出应用时自动安装"
        case .installing(let version):
            return "正在安装 v\(version)，应用即将重启…"
        case .failed(let message):
            return message
        }
    }

    /// 应用是否运行在 Gatekeeper 的临时位置（直接从 dmg / 下载目录打开）。
    /// 这种情况下系统禁止就地替换，Sparkle 会中止更新。
    var isRunningFromTemporaryLocation: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }
}

// MARK: - Sparkle 代理

extension AppUpdater: SPUUpdaterDelegate {

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.phase = .found(version: version)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor [weak self] in
            self?.phase = .upToDate
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
                            with request: NSMutableURLRequest) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.phase = .downloading(version: version)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.phase = .downloaded(version: version)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.phase = .installing(version: version)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor [weak self] in
            self?.phase = .downloaded(version: version)
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        let isSparkleError = nsError.domain == SUSparkleErrorDomain

        // 无更新 / 用户取消 不当作失败
        if isSparkleError && (nsError.code == SparkleErrorCode.noUpdate
            || nsError.code == SparkleErrorCode.updateCheckDeclined) {
            Task { @MainActor [weak self] in
                self?.phase = .upToDate
            }
            return
        }

        let message: String
        if isSparkleError && (nsError.code == SparkleErrorCode.runningFromDiskImage
            || nsError.code == SparkleErrorCode.runningTranslocated) {
            message = "应用在临时位置运行，无法自动更新：请先移到「应用程序」文件夹再打开。"
        } else {
            message = "更新失败：\(nsError.localizedDescription)"
        }

        Task { @MainActor [weak self] in
            self?.phase = .failed(message: message)
        }
    }
}

/// Sparkle 错误码（对应 Sparkle/SUErrors.h 里的 SUError）
private enum SparkleErrorCode {
    static let noUpdate = 1001
    static let runningFromDiskImage = 1003
    static let runningTranslocated = 1005
    static let updateCheckDeclined = 1008
}

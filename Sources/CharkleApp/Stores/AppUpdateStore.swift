import AppKit
import CharkleCore
import Foundation
import SwiftUI
import os

private let updateStoreLogger = Logger(subsystem: "com.charkle.app", category: "AppUpdateStore")

public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(AppReleaseUpdate)
    case downloading(AppReleaseUpdate, progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case verifying(AppReleaseUpdate)
    case readyToInstall(AppReleaseUpdate, stagedAppURL: URL, dmgURL: URL)
    case installing(AppReleaseUpdate)
    case manualInstallRequired(AppReleaseUpdate, dmgURL: URL)
    case failed(String)
}

extension EnvironmentValues {
    @Entry public var charkleAppUpdater: AppUpdateStore? = nil
}

/// Main-actor observable store coordinating native GitHub Releases update checks,
/// streaming DMG downloads, cryptographic + codesign verification, and atomic app relaunch.
@MainActor
@Observable
public final class AppUpdateStore {
    public private(set) var state: AppUpdateState = .idle
    public var isUpdateSheetPresented: Bool = false
    public private(set) var manualInstallReason: String? = nil

    public var autoCheckUpdates: Bool {
        didSet {
            preferences.saveAutoCheckUpdates(autoCheckUpdates)
        }
    }

    public private(set) var lastUpdateCheckAt: Date? {
        didSet {
            preferences.saveLastUpdateCheckAt(lastUpdateCheckAt)
        }
    }

    public private(set) var skippedVersion: String? {
        didSet {
            preferences.saveSkippedVersion(skippedVersion)
        }
    }

    public let currentVersion: CharkleSemanticVersion
    public let currentBuildNumber: String

    @ObservationIgnored private let updater: GitHubReleaseUpdater
    @ObservationIgnored private let preferences: AppUpdatePreferencesStore
    @ObservationIgnored private var hasScheduledLaunchCheck: Bool = false
    @ObservationIgnored private var activeCheckTask: Task<Void, Never>?
    @ObservationIgnored private var activeDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var stagedWorkingDirectoryURL: URL?
    @ObservationIgnored private var lastDiscoveredUpdate: AppReleaseUpdate?

    public init(
        updater: GitHubReleaseUpdater = GitHubReleaseUpdater(),
        preferences: AppUpdatePreferencesStore = AppUpdatePreferencesStore(),
        bundle: Bundle = .main
    ) {
        self.updater = updater
        self.preferences = preferences
        let versionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.0"
        self.currentVersion = CharkleSemanticVersion(parsing: versionString) ?? CharkleSemanticVersion(major: 1, minor: 5, patch: 0)
        self.currentBuildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "12"
        self.autoCheckUpdates = preferences.loadAutoCheckUpdates()
        self.lastUpdateCheckAt = preferences.loadLastUpdateCheckAt()
        self.skippedVersion = preferences.loadSkippedVersion()
    }

    // MARK: - Derived Convenience Accessors

    public var activeUpdate: AppReleaseUpdate? {
        switch state {
        case .available(let update),
             .downloading(let update, _, _, _),
             .verifying(let update),
             .readyToInstall(let update, _, _),
             .installing(let update),
             .manualInstallRequired(let update, _):
            return update
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    public var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }

    public var hasPendingUpdateBanner: Bool {
        activeUpdate != nil
    }

    // MARK: - Deferred Launch Check (Zero Timers / 0.0% Idle CPU)

    /// Schedules a single deferred background check ~4 seconds after app launch.
    /// Strictly zero timers or polling loops: runs once, throttled to once every 6 hours,
    /// respects `autoCheckUpdates` and `skippedVersion`, and reports via a non-blocking callback.
    public func checkForUpdatesIfDueOnLaunch(
        onUpdateAvailable: (@MainActor (AppReleaseUpdate) -> Void)? = nil
    ) {
        guard !hasScheduledLaunchCheck else { return }
        hasScheduledLaunchCheck = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            guard AppUpdateCheckPolicy.shouldRunAutomaticCheck(
                autoCheckEnabled: self.autoCheckUpdates,
                lastCheckAt: self.lastUpdateCheckAt
            ) else {
                return
            }
            guard case .idle = self.state else { return }

            do {
                let outcome = try await self.updater.checkForLatestRelease(currentVersion: self.currentVersion)
                let now = Date()
                self.lastUpdateCheckAt = now

                switch outcome {
                case .upToDate:
                    if case .idle = self.state {
                        self.state = .upToDate(checkedAt: now)
                    }
                case .updateAvailable(let update):
                    guard AppUpdateCheckPolicy.shouldNotifyForUpdate(
                        update.version,
                        skippedVersion: self.skippedVersion,
                        isManual: false
                    ) else {
                        updateStoreLogger.info("Suppressed launch notification for skipped version \(update.tagName, privacy: .public)")
                        return
                    }
                    self.lastDiscoveredUpdate = update
                    self.state = .available(update)
                    onUpdateAvailable?(update)
                }
            } catch {
                // Silent launch check never interrupts the user with an offline error dialog.
                updateStoreLogger.info("Deferred launch update check skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Manual Check

    /// Manually checks GitHub Releases immediately, bypassing throttle and `skippedVersion`.
    public func checkForUpdatesManually(presentSheet: Bool = true) {
        if presentSheet {
            isUpdateSheetPresented = true
        }

        // If a download, verification, or staged install is already underway, just surface it.
        switch state {
        case .downloading, .verifying, .readyToInstall, .installing, .manualInstallRequired:
            return
        case .checking:
            return
        default:
            break
        }

        activeCheckTask?.cancel()
        manualInstallReason = nil
        state = .checking

        activeCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeCheckTask = nil }

            do {
                let outcome = try await self.updater.checkForLatestRelease(currentVersion: self.currentVersion)
                guard !Task.isCancelled else { return }
                let now = Date()
                self.lastUpdateCheckAt = now

                switch outcome {
                case .upToDate:
                    self.lastDiscoveredUpdate = nil
                    self.state = .upToDate(checkedAt: now)
                case .updateAvailable(let update):
                    self.lastDiscoveredUpdate = update
                    self.state = .available(update)
                }
            } catch is CancellationError {
                if case .checking = self.state {
                    self.state = .idle
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Download, Verify & Stage

    /// Downloads the macOS DMG with live progress, verifies CryptoKit SHA-256,
    /// mounts read-only, stages `Charkle.app`, and verifies `Info.plist` + strict `codesign`.
    public func downloadAndPrepareUpdate() {
        let targetUpdate: AppReleaseUpdate?
        switch state {
        case .available(let update):
            targetUpdate = update
        case .failed:
            targetUpdate = lastDiscoveredUpdate
        default:
            targetUpdate = nil
        }

        guard let update = targetUpdate else { return }

        activeDownloadTask?.cancel()
        cleanupStagedDirectory()
        manualInstallReason = nil

        state = .downloading(
            update,
            progress: 0,
            downloadedBytes: 0,
            totalBytes: max(0, update.assetSizeBytes)
        )

        activeDownloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.activeDownloadTask = nil }

            var workDir: URL?
            do {
                let stagingDir = try GitHubReleaseUpdater.makeStagingDirectory()
                workDir = stagingDir
                self.stagedWorkingDirectoryURL = stagingDir

                let dmgURL = try await self.updater.downloadDMG(
                    from: update.downloadURL,
                    suggestedFilename: update.assetName,
                    expectedSizeBytes: update.assetSizeBytes,
                    into: stagingDir,
                    userAgentVersion: self.currentVersion
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading(let current, _, _, _) = self.state, current.id == update.id {
                            self.state = .downloading(
                                current,
                                progress: progress.fraction,
                                downloadedBytes: progress.downloadedBytes,
                                totalBytes: progress.totalBytes
                            )
                        }
                    }
                }

                try Task.checkCancellation()
                self.state = .verifying(update)

                let staged = try await self.updater.stageAndVerifyDMG(
                    dmgURL: dmgURL,
                    workingDirectoryURL: stagingDir,
                    expectedSHA256: update.expectedSHA256
                )

                try Task.checkCancellation()
                self.state = .readyToInstall(
                    update,
                    stagedAppURL: staged.stagedAppURL,
                    dmgURL: staged.dmgURL
                )
            } catch is CancellationError {
                if let workDir {
                    try? FileManager.default.removeItem(at: workDir)
                }
                if self.stagedWorkingDirectoryURL == workDir {
                    self.stagedWorkingDirectoryURL = nil
                }
                self.state = .available(update)
            } catch {
                if let workDir {
                    try? FileManager.default.removeItem(at: workDir)
                }
                if self.stagedWorkingDirectoryURL == workDir {
                    self.stagedWorkingDirectoryURL = nil
                }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelDownload() {
        let fallbackUpdate = activeUpdate ?? lastDiscoveredUpdate
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        cleanupStagedDirectory()
        if let fallbackUpdate {
            state = .available(fallbackUpdate)
        } else {
            state = .idle
        }
    }

    // MARK: - Atomic Install & Relaunch

    /// Atomically replaces the currently running `.app` bundle via a detached `/bin/sh` helper
    /// and terminates the process so it relaunches cleanly.
    /// Falls back to `.manualInstallRequired` and reveals the verified DMG in Finder when
    /// running from a read-only volume, AppTranslocation, non-writable folder, or bare dev binary.
    public func installAndRelaunch(beforeTerminate: (() -> Void)? = nil) {
        guard case let .readyToInstall(update, stagedAppURL, dmgURL) = state else { return }

        switch GitHubReleaseUpdater.evaluateInstallTarget() {
        case .eligible(let targetAppURL):
            guard let workDir = stagedWorkingDirectoryURL else {
                state = .failed("未找到临时更新暂存目录，请重新下载更新。")
                return
            }
            state = .installing(update)
            beforeTerminate?()
            do {
                try updater.launchAtomicSelfUpdate(
                    stagedAppURL: stagedAppURL,
                    targetAppURL: targetAppURL,
                    workingDirectoryURL: workDir
                )
                // Hand off directory cleanup to the detached updater script.
                stagedWorkingDirectoryURL = nil
                NSApplication.shared.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }

        case .manualInstallRequired(let reason):
            manualInstallReason = reason
            state = .manualInstallRequired(update, dmgURL: dmgURL)
            NSWorkspace.shared.activateFileViewerSelecting([dmgURL])
        }
    }

    // MARK: - Secondary Actions & Lifecycle Cleanup

    public func skipVersion(_ version: CharkleSemanticVersion) {
        skippedVersion = version.description
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        cleanupStagedDirectory()
        lastDiscoveredUpdate = nil
        isUpdateSheetPresented = false
        state = .idle
    }

    public func clearSkippedVersion() {
        skippedVersion = nil
    }

    public func openReleasePage() {
        let url = activeUpdate?.releasePageURL
            ?? lastDiscoveredUpdate?.releasePageURL
            ?? updater.repositoryReleasesURL
        NSWorkspace.shared.open(url)
    }

    public func openDownloadedDMG() {
        switch state {
        case .manualInstallRequired(_, let dmgURL), .readyToInstall(_, _, let dmgURL):
            NSWorkspace.shared.open(dmgURL)
        default:
            break
        }
    }

    public func revealDownloadedDMG() {
        switch state {
        case .manualInstallRequired(_, let dmgURL), .readyToInstall(_, _, let dmgURL):
            NSWorkspace.shared.activateFileViewerSelecting([dmgURL])
        default:
            break
        }
    }

    public func cancelBackgroundWorkForTermination() {
        activeCheckTask?.cancel()
        activeCheckTask = nil
        if case .installing = state {
            // Preserve staged directory for the detached atomic swap script.
            return
        }
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        if case .manualInstallRequired = state {
            // Keep verified DMG available if the user is manually installing it.
            return
        }
        cleanupStagedDirectory()
    }

    private func cleanupStagedDirectory() {
        if let dir = stagedWorkingDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
            stagedWorkingDirectoryURL = nil
        }
    }
}

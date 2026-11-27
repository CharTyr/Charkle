import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers
import os

private let appLogger = Logger(subsystem: "com.charkle.app", category: "Lifecycle")

/// Central @MainActor runtime container wiring the `CharkleCore` engine facade to the 4 domain stores,
/// MacBook Notch Shelf controller, and Carbon Global Hotkey manager.
@Observable
public final class CharkleRuntime {
    public static let shared = CharkleRuntime()

    public let engine: any CharkleEngineProtocol
    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let syncAndAI: SyncAndAIStore
    public let extensionBridge: ExtensionBridgeController
    public let appUpdater: AppUpdateStore

    private var notchController: NotchShelfController?
    private let hotkeyManager = GlobalHotkeyManager()
    @ObservationIgnored
    private var hasStartedAppKitServices: Bool = false
    @ObservationIgnored
    private nonisolated(unsafe) var externalRefreshObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var syncCompletedObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var syncProgressiveObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var progressiveMetadataRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var progressiveMetadataPendingBoards: Bool = false
    @ObservationIgnored
    private var progressiveMetadataNeedsAnotherPass: Bool = false
    @ObservationIgnored
    private nonisolated(unsafe) var appBecomeActiveObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var systemDidWakeObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var onboardingRequestObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var windowWillCloseObserver: NSObjectProtocol?
    @ObservationIgnored
    private var lastForegroundSyncDate: Date = .distantPast
    @ObservationIgnored
    private var lastSystemWakeDate: Date = .distantPast
    @ObservationIgnored
    public var openMainWindowHandler: (() -> Void)?
    @ObservationIgnored
    private var isTerminating: Bool = false
    @ObservationIgnored
    private var isTransitioningMinimalMode: Bool = false
    @ObservationIgnored
    private nonisolated(unsafe) var externalRefreshDebounceTask: Task<Void, Never>?

    public init() {
        let resolvedEngine: any CharkleEngineProtocol
        var startupError: String?
        do {
            resolvedEngine = try CharkleEngineFactory.makeDefault()
        } catch {
            appLogger.error("Default engine init failed (\(error.localizedDescription, privacy: .public)); falling back to PlaceholderCharkleEngine")
            startupError = error.localizedDescription
            resolvedEngine = PlaceholderCharkleEngine()
        }

        self.engine = resolvedEngine
        self.coordinator = AppCoordinatorStore()
        self.coordinator.engineStartupError = startupError
        let libraryStore = LibraryStore(engine: resolvedEngine)
        let moodboardStore = MoodboardStore(engine: resolvedEngine)
        let syncStore = SyncAndAIStore(engine: resolvedEngine)
        self.library = libraryStore
        self.moodboards = moodboardStore
        self.syncAndAI = syncStore
        let coordinatorStore = self.coordinator
        self.extensionBridge = ExtensionBridgeController(engine: resolvedEngine) { createdCount, targetBoardID in
            await libraryStore.refreshAll()
            if targetBoardID != nil {
                await moodboardStore.refreshBoards()
            }
            if createdCount > 0 {
                coordinatorStore.showToast(
                    "浏览器扩展已导入 \(createdCount) 项素材",
                    icon: "safari",
                    tone: .success
                )
            }
        }
        self.appUpdater = AppUpdateStore()

        // IMPORTANT (macOS 15 compatibility):
        // Never instantiate `NSHostingView` / `NSPanel` (NotchShelfController) or touch `NSApp`
        // synchronously inside `init()`. On macOS 15.x, creating an `NSHostingView` during
        // `AppGraph.init` / scene construction clears thread-local `AGSubgraph.current`, causing an
        // immediate `AttributeGraph/Attribute.swift:485: attempting to create attribute with no subgraph`
        // trap. AppKit services are started strictly after launch via `startAppKitServicesIfNeeded()`.
    }

    deinit {
        if let observer = externalRefreshObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = syncCompletedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = syncProgressiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        progressiveMetadataRefreshTask?.cancel()
        if let observer = appBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = systemDidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = onboardingRequestObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        externalRefreshDebounceTask?.cancel()
    }

    /// Starts AppKit windows (`NotchShelfController`), Carbon hotkeys, notification observers,
    /// and Dock icon customization strictly after `NSApplication` & `AppGraph` have finished launching.
    public func startAppKitServicesIfNeeded() {
        guard !hasStartedAppKitServices else { return }
        guard NSApp != nil else { return }
        hasStartedAppKitServices = true

        setupNotchAndHotkeys()
        setupExternalAgentLiveRefresh()
        setupRemoteSyncObservers()
        setupOnboardingFocusObserver()
        setupWindowCloseObserver()
        extensionBridge.startIfEnabled()
        CharkleAppIconManager.shared.applyCurrentIcon(updateBundleFileIcon: false)
        if coordinator.isMinimalCaptureMode || coordinator.launchInMinimalCaptureMode {
            applyMinimalCaptureMode(announce: false)
        }
        appUpdater.checkForUpdatesIfDueOnLaunch { [weak self] update in
            guard let self else { return }
            self.coordinator.showToast(
                "发现新版本 \(update.tagName)",
                icon: "arrow.down.circle.fill",
                tone: .neutral,
                duration: 6.5,
                actionTitle: "查看更新"
            ) { [weak self] in
                self?.activateMainWindow()
                self?.appUpdater.isUpdateSheetPresented = true
            }
        }
    }

    public func markTerminating() {
        isTerminating = true
        moodboards.triggerImmediateSaveFlush()
        extensionBridge.stop()
        appUpdater.cancelBackgroundWorkForTermination()
    }

    private func isMainWorkspaceWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else { return false }
        guard window.canBecomeMain else { return false }
        let identifier = window.identifier?.rawValue.lowercased() ?? ""
        if identifier.contains("statusbar") || identifier.contains("menubar") || identifier.contains("settings") {
            return false
        }
        return true
    }

    private func setupWindowCloseObserver() {
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, !self.isTerminating, !self.isTransitioningMinimalMode else { return }
                guard self.coordinator.enterMinimalModeOnWindowClose,
                      !self.coordinator.isMinimalCaptureMode else { return }
                let hasRemainingMain = (NSApp?.windows ?? []).contains {
                    ($0.isVisible || $0.isMiniaturized) && self.isMainWorkspaceWindow($0)
                }
                if !hasRemainingMain {
                    self.enterMinimalCaptureMode()
                }
            }
        }
    }

    public func enterMinimalCaptureMode() {
        startAppKitServicesIfNeeded()
        applyMinimalCaptureMode(announce: true)
    }

    private func applyMinimalCaptureMode(announce: Bool) {
        if !coordinator.notchShelfEnabled {
            coordinator.notchShelfEnabled = true
        }
        coordinator.isMinimalCaptureMode = true
        coordinator.closeQuickLook()
        coordinator.closeSettings()
        coordinator.isJumpAnywherePresented = false
        coordinator.isMoodboardGeneratorPresented = false
        coordinator.isSmartFolderEditorPresented = false
        coordinator.closeSmartDeduplication()

        notchController?.setMinimalCaptureMode(true)
        library.enterMinimalCaptureMode()
        moodboards.enterMinimalCaptureMode()
        RemoteImageMemoryCache.shared.clearAll()
        URLCache.shared.removeAllCachedResponses()

        if let app = NSApp {
            isTransitioningMinimalMode = true
            for window in app.windows where isMainWorkspaceWindow(window) {
                window.orderOut(nil)
                window.close()
            }
            isTransitioningMinimalMode = false
            app.setActivationPolicy(.accessory)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.library.refreshMinimalMetadataOnly()
            await self.moodboards.refreshBoards()
        }

        if announce {
            notchController?.flashConfirmation("已切换至极简刘海模式 · 保留顶部采集与最近素材")
        }
    }

    public func exitMinimalCaptureMode(openMainWindow: Bool = true) {
        let wasMinimal = coordinator.isMinimalCaptureMode
        coordinator.isMinimalCaptureMode = false
        notchController?.setMinimalCaptureMode(false)
        library.exitMinimalCaptureMode()

        if let app = NSApp {
            if app.activationPolicy() != .regular {
                app.setActivationPolicy(.regular)
                CharkleAppIconManager.shared.applyCurrentIcon(updateBundleFileIcon: false)
            }
            app.activate(ignoringOtherApps: true)
        }

        if openMainWindow {
            bringOrOpenMainWindow()
        }

        if wasMinimal {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.library.refreshAll()
                await self.moodboards.refreshBoards()
                await self.syncAndAI.loadAll()
                if self.coordinator.activeMoodboardID == nil {
                    self.coordinator.activeMoodboardID = self.moodboards.boards.first?.id
                }
            }
        }
    }

    public func toggleMinimalCaptureMode() {
        startAppKitServicesIfNeeded()
        if coordinator.isMinimalCaptureMode {
            exitMinimalCaptureMode(openMainWindow: true)
        } else {
            enterMinimalCaptureMode()
        }
    }

    private func setupOnboardingFocusObserver() {
        onboardingRequestObserver = NotificationCenter.default.addObserver(
            forName: AppCoordinatorStore.didRequestOnboardingPresentationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.focusMainWindowForOnboarding()
            }
        }
    }

    public func rerunOnboarding() {
        startAppKitServicesIfNeeded()
        coordinator.presentOnboarding()
    }

    private func focusMainWindowForOnboarding() {
        coordinator.closeSettings()
        guard let app = NSApp else { return }
        for window in app.windows {
            let identifier = window.identifier?.rawValue.lowercased() ?? ""
            let title = window.title.lowercased()
            let isSettingsWindow = identifier.contains("settings")
                || title == "settings"
                || title == "设置"
                || title.contains("偏好设置")
                || title.contains("charkle 设置")
            if isSettingsWindow {
                window.close()
            }
        }
        activateMainWindow()
    }

    private func setupRemoteSyncObservers() {
        syncProgressiveObserver = NotificationCenter.default.addObserver(
            forName: CharkleSyncNotifications.didSyncProgressively,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let kind = notification.userInfo?[CharkleSyncNotifications.progressKindKey] as? String
            let thumbnailIDs = notification.userInfo?[CharkleSyncNotifications.thumbnailAssetIDsKey] as? [UUID]
            let hasBoards = notification.userInfo?[CharkleSyncNotifications.hasBoardsKey] as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                if kind == CharkleSyncNotifications.progressKindThumbnails, let thumbnailIDs, !thumbnailIDs.isEmpty {
                    self.library.thumbnailLoader.invalidate(assetIDs: thumbnailIDs)
                    return
                }
                if kind == CharkleSyncNotifications.progressKindMetadata {
                    if hasBoards {
                        self.progressiveMetadataPendingBoards = true
                    }
                    if self.progressiveMetadataRefreshTask != nil {
                        self.progressiveMetadataNeedsAnotherPass = true
                        return
                    }
                    self.progressiveMetadataRefreshTask = Task { @MainActor [weak self] in
                        defer { self?.progressiveMetadataRefreshTask = nil }
                        while let self, !Task.isCancelled {
                            self.progressiveMetadataNeedsAnotherPass = false
                            let refreshBoards = self.progressiveMetadataPendingBoards
                            self.progressiveMetadataPendingBoards = false
                            if self.coordinator.isMinimalCaptureMode {
                                await self.library.refreshMinimalMetadataOnly()
                                if refreshBoards {
                                    await self.moodboards.refreshBoards()
                                }
                            } else {
                                await self.library.refreshAll()
                                if refreshBoards {
                                    await self.moodboards.refreshBoards()
                                    if let activeBoardID = self.moodboards.activeBoard?.id {
                                        await self.moodboards.reloadActiveBoardIfNeeded(id: activeBoardID)
                                    }
                                }
                            }
                            if !self.progressiveMetadataNeedsAnotherPass {
                                break
                            }
                        }
                    }
                }
            }
        }

        syncCompletedObserver = NotificationCenter.default.addObserver(
            forName: CharkleSyncNotifications.didCompleteSync,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let discovered = notification.userInfo?[CharkleSyncNotifications.discoveredCountKey] as? Int ?? 0
            let downloaded = notification.userInfo?[CharkleSyncNotifications.downloadedOpsKey] as? Int ?? 0
            let renames = notification.userInfo?[CharkleSyncNotifications.reconciledRenamesKey] as? Int ?? 0
            let boards = notification.userInfo?[CharkleSyncNotifications.updatedBoardsKey] as? Int ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.coordinator.isMinimalCaptureMode {
                    await self.library.refreshMinimalMetadataOnly()
                    await self.moodboards.refreshBoards()
                    return
                }
                await self.library.refreshAll()
                await self.moodboards.refreshBoards()
                if let activeBoardID = self.moodboards.activeBoard?.id {
                    await self.moodboards.reloadActiveBoardIfNeeded(id: activeBoardID)
                }
                await self.syncAndAI.refreshSyncStatus()
                if discovered > 0 {
                    self.coordinator.showToast("从云端目录发现并导入 \(discovered) 项新素材", icon: "icloud.and.arrow.down.fill", tone: .success)
                } else if downloaded > 0 || boards > 0 || renames > 0 {
                    self.coordinator.showToast("已同步云端最新变更", icon: "checkmark.icloud.fill")
                }
            }
        }

        systemDidWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastSystemWakeDate = Date()
            }
        }

        appBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.coordinator.isMinimalCaptureMode else { return }
                let now = Date()
                // Avoid poking network/NFS mounts immediately upon Mac sleep wake
                guard now.timeIntervalSince(self.lastSystemWakeDate) >= 15 else { return }
                guard now.timeIntervalSince(self.lastForegroundSyncDate) >= 60 else { return }
                self.lastForegroundSyncDate = now
                _ = await self.syncAndAI.syncQuietlyIfReady()
            }
        }

        // Trigger one quiet initial scan shortly after launch so files dropped in Google Drive while
        // Charkle was closed are automatically ingested without blocking first-paint.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !self.coordinator.isMinimalCaptureMode else { return }
            self.lastForegroundSyncDate = Date()
            _ = await self.syncAndAI.syncQuietlyIfReady()
        }
    }

    private func setupExternalAgentLiveRefresh() {
        externalRefreshObserver = DistributedNotificationCenter.default().addObserver(
            forName: ExternalAgentNotifier.libraryChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let boardIDString = info?["boardID"] as? String
            let summary = info?["summary"] as? String
            let boardID = boardIDString.flatMap(UUID.init(uuidString:))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.externalRefreshDebounceTask?.cancel()
                self.externalRefreshDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self else { return }
                    self.externalRefreshDebounceTask = nil
                    if self.coordinator.isMinimalCaptureMode {
                        await self.library.refreshMinimalMetadataOnly()
                        await self.moodboards.refreshBoards()
                        return
                    }
                    await self.library.refreshAll()
                    await self.moodboards.refreshBoards()
                    if let boardID {
                        await self.moodboards.reloadActiveBoardIfNeeded(id: boardID)
                    }
                    if let summary, !summary.isEmpty {
                        self.coordinator.showToast(summary, icon: "bolt.horizontal.circle.fill")
                    }
                }
            }
        }
    }

    private func setupNotchAndHotkeys() {
        notchController = NotchShelfController(
            coordinator: coordinator,
            library: library,
            moodboards: moodboards,
            onCaptureArea: { [weak self] in
                self?.captureRegionScreenshot()
            },
            onCollectClipboard: { [weak self] in
                self?.collectClipboard()
            },
            onOpenMainWindow: { [weak self] in
                self?.activateMainWindow()
            }
        )

        syncHotkeys(enabled: coordinator.globalHotkeysEnabled)
    }

    public func syncHotkeys(enabled: Bool) {
        if enabled {
            hotkeyManager.register { [weak self] action in
                guard let self else { return }
                switch action {
                case .captureArea:
                    self.captureRegionScreenshot()
                case .toggleNotchShelf:
                    self.toggleNotchShelf()
                case .quickPasteClipboard:
                    self.collectClipboard()
                }
            }
        } else {
            hotkeyManager.unregister()
        }
    }

    public func toggleNotchShelf() {
        startAppKitServicesIfNeeded()
        notchController?.toggle()
    }

    public func syncDefaultNotchTarget(_ mode: NotchTargetMode) {
        notchController?.shelfState.targetMode = mode
    }

    public func activateMainWindow() {
        startAppKitServicesIfNeeded()
        if coordinator.isMinimalCaptureMode {
            exitMinimalCaptureMode(openMainWindow: true)
            return
        }
        guard let app = NSApp else { return }
        if app.activationPolicy() != .regular {
            app.setActivationPolicy(.regular)
            CharkleAppIconManager.shared.applyCurrentIcon(updateBundleFileIcon: false)
        }
        app.activate(ignoringOtherApps: true)
        bringOrOpenMainWindow()
    }

    private func bringOrOpenMainWindow() {
        guard let app = NSApp else { return }
        if let window = app.windows.first(where: { isMainWorkspaceWindow($0) && !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
        } else if let miniaturized = app.windows.first(where: { isMainWorkspaceWindow($0) && $0.isMiniaturized }) {
            miniaturized.deminiaturize(nil)
            miniaturized.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowHandler?()
            Task { @MainActor [weak self] in
                guard let self, let app = NSApp else { return }
                app.activate(ignoringOtherApps: true)
                app.windows.first(where: { self.isMainWorkspaceWindow($0) })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    public func captureRegionScreenshot() {
        Task {
            guard let url = await ScreenshotCapturer.capture(mode: .area) else { return }
            let (folderID, boardID, destLabel) = currentCaptureTarget()
            let created = await library.ingest([.fileURL(url)], targetFolderID: folderID, targetBoardID: boardID)
            if let boardID, !created.isEmpty {
                if !coordinator.isMinimalCaptureMode {
                    await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                }
                await moodboards.refreshBoards()
            }
            try? FileManager.default.removeItem(at: url)
            guard !created.isEmpty else {
                let errMsg = library.lastError ?? "截图保存失败"
                coordinator.showToast(errMsg, icon: "exclamationmark.triangle", tone: .warning)
                notchController?.flashConfirmation(errMsg)
                return
            }
            let msg = "截图已存入「\(destLabel)」(\(created.count) 项)"
            coordinator.showToast(msg, icon: "camera.viewfinder", tone: .success)
            notchController?.flashConfirmation(msg)
        }
    }

    public func collectClipboard() {
        let inputs = ClipboardCollector.extractInputs(from: .general)
        guard !inputs.isEmpty else {
            coordinator.showToast("剪贴板暂无可收藏的图片、链接或文本", icon: "doc.on.clipboard", tone: .warning)
            return
        }
        let hasSocialPost = inputs.contains { input in
            if case .webURL(let url, _, _) = input { return SocialPostURLParser.parse(url) != nil }
            return false
        }
        let hasGitHubRepo = inputs.contains { input in
            if case .webURL(let url, _, _) = input { return GitHubRepoURLParser.parse(url) != nil }
            return false
        }
        let hasGenericWebURL = inputs.contains { input in
            if case .webURL(let url, _, _) = input {
                return SocialPostURLParser.parse(url) == nil && GitHubRepoURLParser.parse(url) == nil
            }
            return false
        }
        let (folderID, boardID, destLabel) = currentCaptureTarget()
        if hasSocialPost {
            notchController?.showProcessing("正在保存推文及媒体…")
        } else if hasGitHubRepo {
            notchController?.showProcessing("正在解析 GitHub 仓库…")
        } else if hasGenericWebURL {
            notchController?.showProcessing("正在解析网页缩略图…")
            coordinator.showToast("正在解析网页缩略图…", icon: "safari")
        }
        Task {
            let created = await library.ingest(inputs, targetFolderID: folderID, targetBoardID: boardID)
            if let boardID, !created.isEmpty {
                if !coordinator.isMinimalCaptureMode {
                    await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                }
                await moodboards.refreshBoards()
            }
            guard !created.isEmpty else {
                let errMsg = library.lastError ?? "收藏失败或该素材已存在"
                coordinator.showToast(errMsg, icon: "exclamationmark.triangle", tone: .warning)
                notchController?.flashConfirmation(errMsg)
                return
            }
            let count = created.count
            let msg: String
            let icon: String
            if hasSocialPost {
                msg = "已保存推文及媒体至「\(destLabel)」(\(count) 项)"
                icon = "checkmark.circle.fill"
            } else if hasGitHubRepo {
                msg = "已收藏 GitHub 仓库至「\(destLabel)」(\(count) 项)"
                icon = "checkmark.circle.fill"
            } else if hasGenericWebURL {
                msg = "已收藏网页书签至「\(destLabel)」(\(count) 项)"
                icon = "safari"
            } else {
                msg = "剪贴板已收入「\(destLabel)」(\(count) 项)"
                icon = "doc.on.clipboard.fill"
            }
            coordinator.showToast(msg, icon: icon, tone: .success)
            notchController?.flashConfirmation(msg)
        }
    }

    public func presentMaterialPackageImportPanel(targetFolderID: UUID? = nil) {
        activateMainWindow()
        let panel = NSOpenPanel()
        panel.title = "导入素材包 / PureRef 场景（.eaglepack / .library / .pur）"
        panel.message = "选择一个或多个 .pur PureRef 场景、.eaglepack 素材包、.library 素材库或 .zip 包，将自动解析素材、目录层级与情绪板排版。"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        var allowed: [UTType] = [.zip, .folder]
        if let purType = UTType(filenameExtension: "pur") {
            allowed.insert(purType, at: 0)
        }
        if let packType = UTType(filenameExtension: "eaglepack") {
            allowed.insert(packType, at: 0)
        }
        if let libType = UTType(filenameExtension: "library") {
            allowed.insert(libType, at: 1)
        }
        panel.allowedContentTypes = allowed

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let selectedURLs = panel.urls
        let resolvedFolderID: UUID? = {
            if let targetFolderID { return targetFolderID }
            if case .folder(let currentID) = coordinator.selectedDestination {
                return currentID
            }
            return nil
        }()

        let pureRefURLs = selectedURLs.filter { PureRefCodec.isPureRefFileURL($0) }
        let packageURLs = selectedURLs.filter { !PureRefCodec.isPureRefFileURL($0) }
        if !pureRefURLs.isEmpty && packageURLs.isEmpty {
            importPureRefURLs(pureRefURLs, targetFolderID: resolvedFolderID)
            return
        }

        coordinator.showToast(
            selectedURLs.count == 1
                ? "正在解析并导入「\(selectedURLs[0].lastPathComponent)」…"
                : "正在解析并导入 \(selectedURLs.count) 个文件…",
            icon: "shippingbox"
        )

        Task {
            let purResults = pureRefURLs.isEmpty
                ? []
                : await library.importPureRefScenes(urls: pureRefURLs, targetFolderID: resolvedFolderID, createMoodboard: true)
            if !purResults.isEmpty {
                await moodboards.refreshBoards()
            }
            let results = packageURLs.isEmpty
                ? []
                : await library.importMaterialPackages(
                    urls: packageURLs,
                    targetFolderID: resolvedFolderID
                )
            let totalAssets = results.reduce(0) { $0 + $1.importedAssets.count }
                + purResults.reduce(0) { $0 + $1.importedAssets.count }
            let totalFolders = results.reduce(0) { $0 + $1.createdFolderCount } + purResults.count
            guard (!results.isEmpty || !purResults.isEmpty), (totalAssets > 0 || totalFolders > 0) else {
                let err = library.lastError ?? "未在所选文件中发现可导入的素材内容"
                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                return
            }

            if results.count == 1 && purResults.isEmpty, let rootID = results[0].rootFolderID {
                coordinator.selectedDestination = .folder(rootID)
                await library.applyDestination(.folder(rootID))
            }
            let summary: String
            if results.count == 1 && purResults.isEmpty {
                let name = results[0].packageName
                summary = totalFolders > 0
                    ? "已导入「\(name)」：新建 \(totalFolders) 个文件夹，收入 \(totalAssets) 项素材"
                    : "已导入「\(name)」：收入 \(totalAssets) 项素材"
            } else {
                summary = totalFolders > 0
                    ? "已完成导入：新建 \(totalFolders) 个文件夹，收入 \(totalAssets) 项素材"
                    : "已完成导入：收入 \(totalAssets) 项素材"
            }
            coordinator.showToast(summary, icon: "shippingbox.fill", tone: .success)
        }
    }

    public func presentPureRefImportPanel(targetFolderID: UUID? = nil) {
        activateMainWindow()
        let panel = NSOpenPanel()
        panel.title = "导入 PureRef 场景（.pur）"
        panel.message = "选择 .pur 场景文件，将自动提取全部图片导入独立文件夹，并按原画布排版与便签生成 Charkle 情绪板。"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let purType = UTType(filenameExtension: "pur") {
            panel.allowedContentTypes = [purType]
        } else {
            panel.allowedContentTypes = [.data]
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let resolvedFolderID: UUID? = {
            if let targetFolderID { return targetFolderID }
            if case .folder(let currentID) = coordinator.selectedDestination {
                return currentID
            }
            return nil
        }()
        importPureRefURLs(panel.urls, targetFolderID: resolvedFolderID)
    }

    private func importPureRefURLs(_ urls: [URL], targetFolderID: UUID?) {
        coordinator.showToast(
            urls.count == 1
                ? "正在解析 PureRef「\(urls[0].deletingPathExtension().lastPathComponent)」…"
                : "正在解析 \(urls.count) 个 PureRef 场景…",
            icon: "square.grid.2x2"
        )
        Task {
            let results = await library.importPureRefScenes(
                urls: urls,
                targetFolderID: targetFolderID,
                createMoodboard: true
            )
            await moodboards.refreshBoards()

            let totalAssets = results.reduce(0) { $0 + $1.importedAssets.count }
            let totalNotes = results.reduce(0) { $0 + $1.importedNoteCount }
            guard !results.isEmpty, (totalAssets > 0 || totalNotes > 0) else {
                coordinator.showToast(
                    library.lastError ?? "未能从所选 .pur 文件中提取到有效图片或便签",
                    icon: "exclamationmark.triangle",
                    tone: .warning
                )
                return
            }

            if results.count == 1, let first = results.first {
                let notePart = first.importedNoteCount > 0 ? "、\(first.importedNoteCount) 条便签" : ""
                let msg = "已导入 PureRef「\(first.sceneName)」：\(first.importedAssets.count) 张图\(notePart)"
                if let boardID = first.createdBoardID {
                    let coord = coordinator
                    coordinator.showToast(
                        msg,
                        icon: "square.grid.2x2.fill",
                        tone: .success,
                        actionTitle: "打开情绪板",
                        onAction: {
                            coord.openMoodboard(boardID)
                        }
                    )
                } else {
                    coordinator.showToast(msg, icon: "square.grid.2x2.fill", tone: .success)
                }
                if let rootID = first.rootFolderID {
                    coordinator.selectedDestination = .folder(rootID)
                    await library.applyDestination(.folder(rootID))
                }
            } else {
                coordinator.showToast(
                    "已导入 \(results.count) 个 PureRef 场景：共收入 \(totalAssets) 张素材并生成情绪板",
                    icon: "square.grid.2x2.fill",
                    tone: .success
                )
            }
        }
    }

    public func syncNowFromMenuBar() {
        Task {
            if let report = await syncAndAI.syncNow() {
                if coordinator.isMinimalCaptureMode {
                    await library.refreshMinimalMetadataOnly()
                } else {
                    await library.refreshAll()
                }
                await moodboards.refreshBoards()
                let msg = "同步完成 · 上传 \(report.uploadedOps) / 拉取 \(report.downloadedOps) / 新发现 \(report.discoveredRemoteAssets)"
                coordinator.showToast(msg, icon: "checkmark.icloud.fill", tone: .success)
                if coordinator.isMinimalCaptureMode {
                    notchController?.flashConfirmation("云端同步完成")
                }
            } else {
                let err = syncAndAI.errorMessage ?? "同步未完成，请检查存储与同步设置"
                coordinator.showToast(err, icon: "exclamationmark.icloud", tone: .warning)
                if coordinator.isMinimalCaptureMode {
                    notchController?.flashConfirmation(err)
                }
            }
        }
    }

    private func currentCaptureTarget() -> (folderID: UUID?, boardID: UUID?, label: String) {
        guard let state = notchController?.shelfState else {
            return (nil, nil, "收件箱")
        }
        switch state.targetMode {
        case .inbox:
            return (nil, nil, "收件箱")
        case .folder:
            let fid = state.selectedFolderID ?? library.folders.first?.id
            let name = library.folders.first(where: { $0.id == fid })?.name ?? "收件箱"
            return (fid, nil, name)
        case .activeMoodboard:
            let bid = coordinator.activeMoodboardID ?? moodboards.boards.first?.id
            let name = moodboards.boards.first(where: { $0.id == bid })?.title ?? "活跃情绪板"
            return (nil, bid, name)
        }
    }
}

final class CharkleAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "charkle.launchInMinimalCaptureMode") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Defer Notch NSPanel / NSHostingView & Dock icon setup until the next MainActor turn,
        // strictly outside SwiftUI's AppGraph / AttributeGraph scene bootstrap transaction.
        Task { @MainActor in
            CharkleRuntime.shared.startAppKitServicesIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            CharkleRuntime.shared.activateMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CharkleRuntime.shared.markTerminating()
    }
}

private struct MainWindowSceneHost: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    let runtime: CharkleRuntime

    var body: some View {
        let accentSource = runtime.coordinator.accentSource
        MainWindowView(
            coordinator: runtime.coordinator,
            library: runtime.library,
            moodboards: runtime.moodboards,
            syncAndAI: runtime.syncAndAI,
            onToggleNotch: { runtime.toggleNotchShelf() },
            onCaptureArea: { runtime.captureRegionScreenshot() },
            onCollectClipboard: { runtime.collectClipboard() },
            onSyncHotkeysEnabled: { runtime.syncHotkeys(enabled: $0) },
            onSyncDefaultNotchTarget: { runtime.syncDefaultNotchTarget($0) },
            onEnterMinimalCaptureMode: { runtime.enterMinimalCaptureMode() },
            onImportMaterialPackage: { runtime.presentMaterialPackageImportPanel() },
            onImportPureRef: { runtime.presentPureRefImportPanel() },
            onAppReady: { runtime.startAppKitServicesIfNeeded() }
        )
        .environment(\.charkleAccentSource, accentSource)
        .environment(\.charkleAppUpdater, runtime.appUpdater)
        .tint(CharkleTheme.accent(for: colorScheme, source: accentSource))
        .sheet(
            isPresented: Binding(
                get: { runtime.appUpdater.isUpdateSheetPresented },
                set: { runtime.appUpdater.isUpdateSheetPresented = $0 }
            )
        ) {
            AppUpdateSheetView(
                appUpdater: runtime.appUpdater,
                onPrepareQuitForUpdate: { runtime.markTerminating() }
            )
            .environment(\.charkleAccentSource, accentSource)
            .tint(CharkleTheme.accent(for: colorScheme, source: accentSource))
        }
        .onAppear {
            runtime.openMainWindowHandler = {
                openWindow(id: "main")
            }
        }
    }
}

private struct CharkleMenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    let runtime: CharkleRuntime

    private var menuBarSyncLabel: String {
        let enabled = runtime.syncAndAI.syncConfig.enabledBackends
        if enabled.count > 1 {
            return "立即同步全部后端（\(enabled.count)）"
        }
        switch runtime.syncAndAI.syncConfig.mode {
        case .localOnly: return "立即扫描本地素材库"
        case .iCloudDrive: return "立即同步 iCloud Drive"
        case .webDAV: return "立即同步 WebDAV"
        case .directAPIWithGDirect, .gdirectMount: return "立即同步 Google Drive"
        }
    }

    private func registerWindowOpener() {
        runtime.openMainWindowHandler = {
            openWindow(id: "main")
        }
    }

    var body: some View {
        if runtime.coordinator.isMinimalCaptureMode {
            Button("恢复 Charkle 主窗口（退出极简模式）") {
                registerWindowOpener()
                runtime.exitMinimalCaptureMode(openMainWindow: true)
            }
            Text("极简刘海模式运行中 · 最低资源占用")
        } else {
            Button("打开 Charkle 主窗口") {
                registerWindowOpener()
                runtime.activateMainWindow()
            }
            Button("切换至极简刘海模式（仅保留刘海采集）") {
                registerWindowOpener()
                runtime.enterMinimalCaptureMode()
            }
        }
        Divider()
        Button("展开 / 收起刘海浮窗 (⌥⇧S)") {
            runtime.toggleNotchShelf()
        }
        Button("区域截图采集 (⌥⇧A)") {
            runtime.captureRegionScreenshot()
        }
        Button("收藏当前剪贴板 (⌥⇧V)") {
            runtime.collectClipboard()
        }
        Divider()
        Button("快速生成情绪板…") {
            registerWindowOpener()
            runtime.activateMainWindow()
            runtime.coordinator.presentMoodboardGenerator(entry: .prompt)
        }
        Button(menuBarSyncLabel) {
            runtime.syncNowFromMenuBar()
        }
        Button("重新运行首次引导…") {
            registerWindowOpener()
            runtime.activateMainWindow()
            runtime.rerunOnboarding()
        }
        Button("检查更新…") {
            registerWindowOpener()
            runtime.activateMainWindow()
            runtime.appUpdater.checkForUpdatesManually(presentSheet: true)
        }
        Button("设置…") {
            registerWindowOpener()
            runtime.activateMainWindow()
            runtime.coordinator.openSettings()
        }
        Divider()
        Button("退出 Charkle") {
            runtime.markTerminating()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

@main
struct CharkleApp: App {
    @NSApplicationDelegateAdaptor(CharkleAppDelegate.self) private var appDelegate
    private let runtime = CharkleRuntime.shared

    var body: some Scene {
        WindowGroup("Charkle", id: "main") {
            MainWindowSceneHost(runtime: runtime)
                .frame(minWidth: 800, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    runtime.activateMainWindow()
                    runtime.appUpdater.checkForUpdatesManually(presentSheet: true)
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    runtime.activateMainWindow()
                    runtime.coordinator.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .help) {
                Button("重新运行首次使用引导…") {
                    runtime.activateMainWindow()
                    runtime.rerunOnboarding()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("快速生成情绪板…") {
                    runtime.activateMainWindow()
                    runtime.coordinator.presentMoodboardGenerator(entry: .prompt)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("新建空白情绪板") {
                    runtime.activateMainWindow()
                    Task {
                        if let doc = await runtime.moodboards.createBlankBoard(title: "未命名情绪板") {
                            runtime.coordinator.openMoodboard(doc.id)
                        }
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("导入素材包（.eaglepack / .library / .pur）…") {
                    runtime.presentMaterialPackageImportPanel()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("导入 PureRef 场景（.pur）…") {
                    runtime.presentPureRefImportPanel()
                }

                Button("智能去重（全媒体，保留最高质量）…") {
                    runtime.activateMainWindow()
                    runtime.coordinator.presentSmartDeduplication()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    if Self.isEditingTextInKeyWindow() {
                        _ = NSApp?.sendAction(Selector(("undo:")), to: nil, from: nil)
                    } else if runtime.coordinator.isViewingMoodboard
                        && !runtime.coordinator.isModalOverlayPresented
                        && runtime.moodboards.canUndo {
                        runtime.moodboards.undo()
                    } else {
                        _ = NSApp?.sendAction(Selector(("undo:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("重做") {
                    if Self.isEditingTextInKeyWindow() {
                        _ = NSApp?.sendAction(Selector(("redo:")), to: nil, from: nil)
                    } else if runtime.coordinator.isViewingMoodboard
                        && !runtime.coordinator.isModalOverlayPresented
                        && runtime.moodboards.canRedo {
                        runtime.moodboards.redo()
                    } else {
                        _ = NSApp?.sendAction(Selector(("redo:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandMenu("灵感采集") {
                Button("快速跳转…") {
                    guard !runtime.coordinator.isOnboardingPresented else { return }
                    let willOpen = !runtime.coordinator.isJumpAnywherePresented
                    if willOpen {
                        runtime.coordinator.closeQuickLook()
                        runtime.coordinator.closeSettings()
                    }
                    runtime.coordinator.isJumpAnywherePresented = willOpen
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("显示 / 隐藏筛选面板") {
                    runtime.coordinator.isVisualFilterBarPresented.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("显示 / 隐藏右侧检查器") {
                    runtime.coordinator.isInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("收起 / 展开侧边栏为仅图标") {
                    runtime.coordinator.isSidebarCollapsed.toggle()
                }
                .keyboardShortcut("\\", modifiers: .command)

                Divider()

                Button("区域截图采集") {
                    runtime.captureRegionScreenshot()
                }
                .keyboardShortcut("a", modifiers: [.option, .shift])

                Button("采集剪贴板内容") {
                    runtime.collectClipboard()
                }
                .keyboardShortcut("v", modifiers: [.option, .shift])

                Button("展开 / 收起刘海浮窗") {
                    runtime.toggleNotchShelf()
                }
                .keyboardShortcut("s", modifiers: [.option, .shift])

                Divider()

                Button(runtime.coordinator.isMinimalCaptureMode ? "恢复完整主窗口" : "切换至极简刘海模式（最低占用）") {
                    runtime.toggleMinimalCaptureMode()
                }
                .keyboardShortcut("m", modifiers: [.option, .shift])
            }
        }

        MenuBarExtra {
            CharkleMenuBarContentView(runtime: runtime)
        } label: {
            Image(nsImage: CharkleMenuBarIcon.templateImage())
        }
    }

    private static func isEditingTextInKeyWindow() -> Bool {
        guard let responder = NSApp?.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSText
    }
}

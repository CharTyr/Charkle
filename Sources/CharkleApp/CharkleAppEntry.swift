import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import os

private let appLogger = Logger(subsystem: "com.charkle.app", category: "Lifecycle")

/// Central @MainActor runtime container wiring the `CharkleCore` engine facade to the 4 domain stores,
/// MacBook Notch Shelf controller, and Carbon Global Hotkey manager.
@Observable
public final class CharkleRuntime {
    public let engine: any CharkleEngineProtocol
    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let syncAndAI: SyncAndAIStore

    private var notchController: NotchShelfController?
    private let hotkeyManager = GlobalHotkeyManager()
    @ObservationIgnored
    private nonisolated(unsafe) var externalRefreshObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var syncCompletedObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var appBecomeActiveObserver: NSObjectProtocol?
    @ObservationIgnored
    private var lastForegroundSyncDate: Date = .distantPast

    public init() {
        let resolvedEngine: any CharkleEngineProtocol
        do {
            resolvedEngine = try CharkleEngineFactory.makeDefault()
        } catch {
            appLogger.error("Default engine init failed (\(error.localizedDescription, privacy: .public)); falling back to PlaceholderCharkleEngine")
            resolvedEngine = PlaceholderCharkleEngine()
        }

        self.engine = resolvedEngine
        self.coordinator = AppCoordinatorStore()
        self.library = LibraryStore(engine: resolvedEngine)
        self.moodboards = MoodboardStore(engine: resolvedEngine)
        self.syncAndAI = SyncAndAIStore(engine: resolvedEngine)

        setupNotchAndHotkeys()
        setupExternalAgentLiveRefresh()
        setupRemoteSyncObservers()
    }

    deinit {
        if let observer = externalRefreshObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = syncCompletedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appBecomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupRemoteSyncObservers() {
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
                await self.library.refreshAll()
                await self.moodboards.refreshBoards()
                if let activeBoardID = self.moodboards.activeBoard?.id {
                    await self.moodboards.reloadActiveBoardIfNeeded(id: activeBoardID)
                }
                self.syncAndAI.syncStatus = await self.engine.syncStatus()
                if discovered > 0 {
                    self.coordinator.showToast("从云端目录发现并导入 \(discovered) 项新素材", icon: "icloud.and.arrow.down.fill", tone: .success)
                } else if downloaded > 0 || boards > 0 || renames > 0 {
                    self.coordinator.showToast("已同步云端最新变更", icon: "checkmark.icloud.fill")
                }
            }
        }

        appBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastForegroundSyncDate) >= 20 else { return }
                self.lastForegroundSyncDate = now
                _ = await self.syncAndAI.syncQuietlyIfReady()
            }
        }

        // Trigger one quiet initial scan shortly after launch so files dropped in Google Drive while
        // Charkle was closed are automatically ingested without blocking first-paint.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self else { return }
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
        notchController?.toggle()
    }

    public func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func captureRegionScreenshot() {
        Task {
            guard let url = await ScreenshotCapturer.capture(mode: .area) else { return }
            let (folderID, boardID, destLabel) = currentCaptureTarget()
            let created = await library.ingest([.fileURL(url)], targetFolderID: folderID, targetBoardID: boardID)
            if let boardID {
                await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                await moodboards.refreshBoards()
            }
            try? FileManager.default.removeItem(at: url)
            let msg = "截图已存入「\(destLabel)」(\(max(created.count, 1)) 项)"
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
        let hasXPost = inputs.contains { input in
            if case .webURL(let url, _, _) = input { return XPostURLParser.parse(url) != nil }
            return false
        }
        let (folderID, boardID, destLabel) = currentCaptureTarget()
        if hasXPost {
            notchController?.showProcessing("正在保存 X 推文及媒体…")
        }
        Task {
            let created = await library.ingest(inputs, targetFolderID: folderID, targetBoardID: boardID)
            if let boardID {
                await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                await moodboards.refreshBoards()
            }
            let count = max(created.count, inputs.count)
            let msg = hasXPost
                ? "已保存 X 推文及媒体至「\(destLabel)」(\(count) 项)"
                : "剪贴板已收入「\(destLabel)」(\(count) 项)"
            coordinator.showToast(msg, icon: hasXPost ? "checkmark.circle.fill" : "doc.on.clipboard.fill", tone: .success)
            notchController?.flashConfirmation(msg)
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

@main
struct CharkleApp: App {
    @State private var runtime = CharkleRuntime()

    var body: some Scene {
        WindowGroup("Charkle") {
            MainWindowView(
                coordinator: runtime.coordinator,
                library: runtime.library,
                moodboards: runtime.moodboards,
                syncAndAI: runtime.syncAndAI,
                onToggleNotch: { runtime.toggleNotchShelf() },
                onCaptureArea: { runtime.captureRegionScreenshot() },
                onCollectClipboard: { runtime.collectClipboard() }
            )
            .frame(minWidth: 1020, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("快速生成情绪板…") {
                    runtime.coordinator.presentMoodboardGenerator(entry: .prompt)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("新建空白情绪板") {
                    Task {
                        if let doc = await runtime.moodboards.createBlankBoard(title: "未命名情绪板") {
                            runtime.coordinator.openMoodboard(doc.id)
                        }
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .undoRedo) {
                Button("撤销画布编辑") {
                    runtime.moodboards.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!runtime.coordinator.isViewingMoodboard || !runtime.moodboards.canUndo)

                Button("重做画布编辑") {
                    runtime.moodboards.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!runtime.coordinator.isViewingMoodboard || !runtime.moodboards.canRedo)
            }

            CommandMenu("灵感采集") {
                Button("快速跳转…") {
                    runtime.coordinator.isJumpAnywherePresented.toggle()
                }
                .keyboardShortcut("j", modifiers: .command)

                Button("显示 / 隐藏视觉筛选条") {
                    runtime.coordinator.isVisualFilterBarPresented.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("显示 / 隐藏右侧检查器") {
                    runtime.coordinator.isInspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

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
            }
        }

        Settings {
            SettingsView(
                coordinator: runtime.coordinator,
                syncAndAI: runtime.syncAndAI,
                onToggleNotchPreview: { runtime.toggleNotchShelf() },
                onSyncHotkeysEnabled: { runtime.syncHotkeys(enabled: $0) }
            )
        }

        MenuBarExtra("Charkle", systemImage: "rectangle.3.group") {
            Button("打开 Charkle 主窗口") {
                runtime.activateMainWindow()
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
                runtime.activateMainWindow()
                runtime.coordinator.presentMoodboardGenerator(entry: .prompt)
            }
            Button("立即同步 Google Drive") {
                Task {
                    _ = await runtime.syncAndAI.syncNow()
                    await runtime.library.refreshAll()
                    await runtime.moodboards.refreshBoards()
                }
            }
            Divider()
            Button("退出 Charkle") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

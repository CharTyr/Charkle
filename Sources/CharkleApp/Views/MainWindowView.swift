import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Gallery-First primary window shell with restrained Apple Liquid Glass floating islands,
/// soft scroll edge fade, unified inline token search + filter popover, Inbox Triage bar,
/// Moodboards Home, Dual-Mode Moodboard Studio, adaptive Inspector, Quick Look continuity, and Jump Anywhere.
public struct MainWindowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotch: () -> Void
    public let onCaptureArea: () -> Void
    public let onCollectClipboard: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void
    public let onEnterMinimalCaptureMode: () -> Void
    public let onAppReady: () -> Void

    @Namespace private var heroNamespace

    @State private var searchDraft: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var colorToleranceDebounceTask: Task<Void, Never>?
    @State private var isSidebarVisible: Bool = true
    @State private var quickBatchTagDraft: String = ""
    @State private var showBatchTagPopover: Bool = false
    @State private var pendingPermanentDeleteIDs: [UUID] = []
    @State private var showCreateSubfolderPopover: Bool = false
    @State private var subfolderNameDraft: String = ""
    @State private var showInboxBatchTriageSheet: Bool = false
    @State private var selectedTriageIDs: Set<UUID> = []
    @State private var galleryViewportWidth: CGFloat = 960
    @FocusState private var isSubfolderFieldFocused: Bool

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: coordinator.accentSource)
    }

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        syncAndAI: SyncAndAIStore,
        onToggleNotch: @escaping () -> Void,
        onCaptureArea: @escaping () -> Void,
        onCollectClipboard: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void = { _ in },
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in },
        onEnterMinimalCaptureMode: @escaping () -> Void = {},
        onAppReady: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.syncAndAI = syncAndAI
        self.onToggleNotch = onToggleNotch
        self.onCaptureArea = onCaptureArea
        self.onCollectClipboard = onCollectClipboard
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
        self.onEnterMinimalCaptureMode = onEnterMinimalCaptureMode
        self.onAppReady = onAppReady
    }

    public var body: some View {
        if coordinator.isMinimalCaptureMode {
            Color.clear
                .frame(width: 1, height: 1)
                .task {
                    onAppReady()
                }
        } else {
            mainWorkspaceBody
        }
    }

    private var mainWorkspaceBody: some View {
        ZStack {
            // Native 3-pane studio layout (avoids macOS 26/27 NavigationSplitView + hiddenTitleBar
            // ScrollView safe-area hit-test vertical offset bug, ensuring 0px-accurate sidebar clicks).
            // Sidebar and Inspector keep deterministic fixed internal widths inside animated width slots
            // so rapid collapse/expand cycles never get stuck half-open or overflow past window bounds.
            HStack(spacing: 0) {
                let sidebarTargetWidth: CGFloat = coordinator.isSidebarCollapsed ? 76 : 232
                HStack(spacing: 0) {
                    SidebarView(
                        coordinator: coordinator,
                        library: library,
                        moodboards: moodboards,
                        onSelectDestination: { dest in
                            navigate(to: dest)
                        },
                        onDropAssetsOntoFolder: { ids, folderID in
                            Task {
                                await library.moveAssets(ids, toFolderID: folderID)
                                let targetName = folderID.flatMap { library.folder(byID: $0)?.name } ?? "收件箱"
                                coordinator.showToast("已移动 \(ids.count) 项到「\(targetName)」", icon: "folder")
                            }
                        },
                        onDropExternalOntoFolder: { inputs, folderID in
                            Task {
                                let created = await library.ingest(inputs, targetFolderID: folderID, targetBoardID: nil)
                                if created.isEmpty {
                                    coordinator.showToast(library.lastError ?? "导入失败或素材已存在", icon: "exclamationmark.triangle", tone: .warning)
                                } else {
                                    coordinator.showToast("已导入 \(created.count) 项素材", icon: "arrow.down.circle.fill", tone: .success)
                                }
                            }
                        },
                        onDropAssetsOntoBoard: { ids, boardID in
                            let resolved = ids.compactMap { library.allAssetsByID[$0] }
                            Task {
                                await moodboards.addAssetsToSpecificBoard(boardID: boardID, assets: resolved)
                                let title = moodboards.boards.first(where: { $0.id == boardID })?.title ?? "情绪板"
                                coordinator.showToast("已加入情绪板「\(title)」(\(resolved.count) 项)", icon: "rectangle.3.group")
                            }
                        },
                        onDropExternalOntoBoard: { inputs, boardID in
                            Task {
                                let created = await library.ingest(inputs, targetFolderID: nil, targetBoardID: boardID)
                                if created.isEmpty {
                                    coordinator.showToast(library.lastError ?? "导入失败或素材已存在", icon: "exclamationmark.triangle", tone: .warning)
                                } else {
                                    await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                                    await moodboards.refreshBoards()
                                    coordinator.showToast("已收入并上板 (\(created.count) 项)", icon: "sparkles.rectangle.stack", tone: .success)
                                }
                            }
                        }
                    )
                    .frame(width: sidebarTargetWidth, alignment: .leading)
                    .clipped()
                    .background {
                        CharkleSidebarMaterialBackground()
                    }

                    Rectangle()
                        .fill(CharkleTheme.hairline(for: colorScheme))
                        .frame(width: 1)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                .opacity(isSidebarVisible ? 1 : 0)
                .allowsHitTesting(isSidebarVisible)
                .disabled(!isSidebarVisible)
                .accessibilityHidden(!isSidebarVisible)
                .frame(width: isSidebarVisible ? (sidebarTargetWidth + 1) : 0, alignment: .trailing)
                .ignoresSafeArea(.container, edges: .top)
                .clipped()
                .layoutPriority(1)

                centerWorkspace
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .background {
                        Color.clear
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                floor(max(240, proxy.size.width))
                            } action: { _, newWidth in
                                if abs(newWidth - galleryViewportWidth) >= 2 {
                                    galleryViewportWidth = newWidth
                                }
                            }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .clipped()
                    .layoutPriority(0)

                InspectorView(
                    coordinator: coordinator,
                    library: library,
                    moodboards: moodboards,
                    onCopyHex: { copyColorHex($0) },
                    onFilterByColor: { hex in
                        Task {
                            coordinator.selectedDestination = .allItems
                            await library.applyDestination(.allItems)
                            await library.filterByColorHex(hex)
                            coordinator.isVisualFilterBarPresented = true
                        }
                    },
                    onOpenQuickLook: { asset in
                        openQuickLook(asset)
                    },
                    onCopyBoardImage: {
                        copyCurrentBoardImage(options: MoodboardExportOptions(darkAppearance: colorScheme == .dark))
                    },
                    onSaveBoardImage: { fmt in
                        saveCurrentBoardImage(format: fmt, options: MoodboardExportOptions(darkAppearance: colorScheme == .dark))
                    },
                    onExportFigmaBundle: {
                        exportCurrentBoardToFigmaBundle(options: MoodboardExportOptions(darkAppearance: colorScheme == .dark))
                    },
                    onOpenFigmaPluginGuide: {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                            coordinator.openSettings(tab: .extensions)
                        }
                    }
                )
                .frame(width: 300)
                .frame(minHeight: 0, maxHeight: .infinity)
                .opacity(coordinator.isInspectorVisible ? 1 : 0)
                .allowsHitTesting(coordinator.isInspectorVisible)
                .disabled(!coordinator.isInspectorVisible)
                .accessibilityHidden(!coordinator.isInspectorVisible)
                .frame(width: coordinator.isInspectorVisible ? 300 : 0, alignment: .leading)
                .ignoresSafeArea(.container, edges: .top)
                .clipped()
                .layoutPriority(1)
            }
            .ignoresSafeArea(.container, edges: .top)
            .animation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion), value: isSidebarVisible)
            .animation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion), value: coordinator.isSidebarCollapsed)
            .animation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion), value: coordinator.isInspectorVisible)

            // Full-Media Quick Look Hero Continuity Overlay
            if let qlID = coordinator.quickLookAssetID,
               let qlAsset = library.allAssetsByID[qlID] ?? library.assets.first(where: { $0.id == qlID }) {
                QuickLookOverlayView(
                    asset: qlAsset,
                    library: library,
                    moodboards: moodboards,
                    coordinator: coordinator,
                    heroNamespace: heroNamespace,
                    onClose: {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                            coordinator.closeQuickLook()
                        }
                    },
                    onStep: { delta in
                        coordinator.stepQuickLook(delta: delta)
                    },
                    onCopyHex: { copyColorHex($0) },
                    onFilterByColor: { hex in
                        Task {
                            coordinator.selectedDestination = .allItems
                            await library.applyDestination(.allItems)
                            await library.filterByColorHex(hex)
                            coordinator.isVisualFilterBarPresented = true
                        }
                    }
                )
                .ignoresSafeArea(.all)
                .zIndex(200)
                .transition(.opacity)
            }

            // Jump Anywhere Command Palette (⌘J)
            if coordinator.isJumpAnywherePresented {
                JumpAnywhereView(
                    coordinator: coordinator,
                    library: library,
                    onSelectMatch: { match in
                        handleJumpMatch(match)
                    },
                    onTriggerQuickCommand: { cmd in
                        handleQuickCommand(cmd)
                    },
                    onClose: {
                        coordinator.isJumpAnywherePresented = false
                    }
                )
                .zIndex(250)
            }

            // Centered Settings Overlay (⌘, or bottom-left sidebar gear)
            if coordinator.isSettingsPresented {
                SettingsOverlayView(
                    coordinator: coordinator,
                    library: library,
                    syncAndAI: syncAndAI,
                    onToggleNotchPreview: onToggleNotch,
                    onSyncHotkeysEnabled: onSyncHotkeysEnabled,
                    onSyncDefaultNotchTarget: onSyncDefaultNotchTarget,
                    onEnterMinimalCaptureMode: onEnterMinimalCaptureMode,
                    onClose: {
                        withAnimation(CharkleMotion.enterExit(false, enter: CharkleMotion.enterMd, exit: CharkleMotion.exitMd, reduced: reduceMotion)) {
                            coordinator.closeSettings()
                        }
                    }
                )
                .zIndex(260)
                .transition(.opacity)
            }

            // First-Launch & Re-Runnable Onboarding Studio
            if coordinator.isOnboardingPresented {
                OnboardingView(
                    coordinator: coordinator,
                    syncAndAI: syncAndAI,
                    onToggleNotchPreview: onToggleNotch,
                    onSyncHotkeysEnabled: onSyncHotkeysEnabled,
                    onSyncDefaultNotchTarget: onSyncDefaultNotchTarget,
                    onOpenSettings: { tab in
                        coordinator.openSettings(tab: tab)
                    },
                    onFinish: {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.exitMd, reduced: reduceMotion)) {
                            coordinator.completeOnboarding()
                        }
                    }
                )
                .id(coordinator.onboardingRunID)
                .zIndex(280)
                .transition(.opacity)
            }

            // Interactive Floating Liquid Glass Toasts (Top-Trailing, hover-pause + Undo countdown)
            CharkleToastOverlay(coordinator: coordinator)
                .zIndex(300)
        }
        .environment(\.charkleAccentSource, coordinator.accentSource)
        .tint(activeAccent)
        .background {
            ZStack {
                CharkleWindowChromeBridge()
                WindowKeyEventBridge { event, hostWindow in
                    handleMainWindowKeyDown(event, in: hostWindow)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(
            CharkleMotion.enterExit(
                coordinator.isOnboardingPresented,
                enter: CharkleMotion.enterLg,
                exit: CharkleMotion.exitMd,
                reduced: reduceMotion
            ),
            value: coordinator.isOnboardingPresented
        )
        .animation(
            CharkleMotion.enterExit(
                coordinator.isSettingsPresented,
                enter: CharkleMotion.enterMd,
                exit: CharkleMotion.exitMd,
                reduced: reduceMotion
            ),
            value: coordinator.isSettingsPresented
        )
        .sheet(isPresented: Binding(
            get: { coordinator.isMoodboardGeneratorPresented },
            set: { coordinator.isMoodboardGeneratorPresented = $0 }
        )) {
            MoodboardGeneratorSheet(
                coordinator: coordinator,
                library: library,
                moodboards: moodboards,
                syncAndAI: syncAndAI
            )
            .environment(\.charkleAccentSource, coordinator.accentSource)
            .tint(activeAccent)
        }
        .sheet(isPresented: $showInboxBatchTriageSheet) {
            inboxBatchTriageSheet
                .environment(\.charkleAccentSource, coordinator.accentSource)
                .tint(activeAccent)
        }
        .sheet(isPresented: Binding(
            get: { coordinator.isSmartFolderEditorPresented },
            set: { coordinator.isSmartFolderEditorPresented = $0 }
        )) {
            SmartFolderEditorSheet(
                library: library,
                existing: coordinator.editingSmartFolder
            ) { saved in
                Task {
                    await library.saveSmartFolder(saved)
                    coordinator.showToast("已保存智能文件夹「\(saved.name)」", icon: "folder.badge.gearshape")
                    navigate(to: .smartFolder(saved.id))
                }
            }
            .environment(\.charkleAccentSource, coordinator.accentSource)
            .tint(activeAccent)
        }
        .alert(
            pendingPermanentDeleteIDs.count == library.assets.count && coordinator.selectedDestination == .trash && pendingPermanentDeleteIDs.count > 1
                ? "清空废纸篓（共 \(pendingPermanentDeleteIDs.count) 项）？"
                : "彻底删除 \(pendingPermanentDeleteIDs.count) 项素材？",
            isPresented: Binding(
                get: { !pendingPermanentDeleteIDs.isEmpty },
                set: { if !$0 { pendingPermanentDeleteIDs = [] } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingPermanentDeleteIDs = []
            }
            Button("彻底删除", role: .destructive) {
                let ids = pendingPermanentDeleteIDs
                pendingPermanentDeleteIDs = []
                Task {
                    await library.permanentlyDeleteAssets(ids)
                    coordinator.showToast("已彻底删除 \(ids.count) 项素材", icon: "trash.slash")
                }
            }
        } message: {
            Text("彻底删除后将无法从废纸篓恢复。")
        }
        .alert(
            "素材库数据库初始化失败",
            isPresented: Binding(
                get: { coordinator.engineStartupError != nil },
                set: { if !$0 { coordinator.engineStartupError = nil } }
            )
        ) {
            Button("在访达中打开数据目录") {
                let dir = ExternalAgentConfigStore.defaultDirectory()
                NSWorkspace.shared.open(dir)
                coordinator.engineStartupError = nil
            }
            Button("知道了", role: .cancel) {
                coordinator.engineStartupError = nil
            }
        } message: {
            Text("当前已临时回退至内存占位模式，新导入的内容在退出后不会保存。错误原因：\(coordinator.engineStartupError ?? "未知错误")")
        }
        .task {
            onAppReady()
            await library.bootstrap()
            await moodboards.refreshBoards()
            await syncAndAI.loadAll()
            if coordinator.activeMoodboardID == nil {
                coordinator.activeMoodboardID = moodboards.boards.first?.id
            }
            coordinator.presentOnboardingIfFirstLaunch()
        }
        .onChange(of: searchDraft) { _, newValue in
            searchDebounceTask?.cancel()
            library.filter.searchQuery = newValue
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                library.semanticSearchReport = nil
                searchDebounceTask = Task {
                    await library.refreshAssets()
                }
            } else if !library.semanticSearchEnabled {
                library.semanticSearchReport = nil
                searchDebounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    await library.refreshAssets()
                }
            }
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            searchDebounceTask = nil
            colorToleranceDebounceTask?.cancel()
            colorToleranceDebounceTask = nil
        }
        .onChange(of: coordinator.selectedDestination) { _, newDest in
            if case .moodboard(let id) = newDest {
                coordinator.activeMoodboardID = id
                Task { await moodboards.openBoard(id: id) }
            }
        }
        .onChange(of: library.assetsRevision) { _, _ in
            if let qlID = coordinator.quickLookAssetID,
               !library.isLoading,
               library.allAssetsByID[qlID] == nil,
               !library.assets.contains(where: { $0.id == qlID }) {
                coordinator.closeQuickLook()
            }
        }
    }

    // MARK: - Center Workspace Switcher

    @ViewBuilder
    private var centerWorkspace: some View {
        switch coordinator.selectedDestination {
        case .moodboardsHome:
            moodboardsHomeStage
        case .moodboard:
            moodboardStudioStage
        default:
            libraryGalleryStage
        }
    }

    // MARK: - 1. Library Gallery Stage (Section Context + 3 Liquid Glass Islands + Virtualized Masonry)

    private var libraryGalleryStage: some View {
        let isInbox = coordinator.selectedDestination == .inbox
        let isTrash = coordinator.selectedDestination == .trash
        let activeFolderID: UUID? = if case .folder(let fid) = coordinator.selectedDestination { fid } else { nil }
        let activeFolderChildren: [FolderRecord] = activeFolderID.map { library.childFolders(of: $0) } ?? []
        let showFolderSubbar = activeFolderID != nil && (!activeFolderChildren.isEmpty || galleryViewportWidth < 680)
        let topInset: CGFloat = {
            var base: CGFloat = 62
            if library.semanticSearchReport != nil { base += 44 }
            if isInbox && !library.assets.isEmpty { base += 50 }
            if isTrash && !library.assets.isEmpty { base += 50 }
            if showFolderSubbar { base += 50 }
            return base
        }()

        return ZStack(alignment: .top) {
            if isInbox && library.assets.isEmpty && !library.isLoading && !library.filter.hasActiveVisualFilters && library.filter.searchQuery.isEmpty {
                inboxZeroCelebrationView
            } else if library.assets.isEmpty && !library.isLoading {
                emptyLibraryView
            } else if coordinator.galleryLayoutMode == .ringGallery {
                GalleryRingView(
                    assets: library.assets,
                    folders: library.folders,
                    boards: moodboards.boards,
                    activeMoodboardID: coordinator.activeMoodboardID,
                    isOverlayPresented: coordinator.isModalOverlayPresented || showInboxBatchTriageSheet,
                    loader: library.thumbnailLoader,
                    selectedAssetIDs: Binding(
                        get: { library.selectedAssetIDs },
                        set: { library.selectedAssetIDs = $0 }
                    ),
                    topContentInset: topInset,
                    onOpenQuickLook: { asset in
                        openQuickLook(asset)
                    },
                    onMarkOpened: { id in
                        library.markAssetOpened(id)
                    },
                    onCopyAssets: { ids in
                        Task {
                            let count = await library.copyAssetsToPasteboard(ids)
                            coordinator.showToast("已拷贝 \(count) 项素材到剪贴板", icon: "doc.on.doc")
                        }
                    },
                    onRevealInFinder: { id in
                        Task {
                            let ok = await library.revealInFinder(assetID: id)
                            if !ok {
                                coordinator.showToast("无法定位该素材的本地文件", icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onAddToMoodboard: { ids, boardID in
                        let items = ids.compactMap { library.allAssetsByID[$0] }
                        guard !items.isEmpty else { return }
                        if let targetBoardID = boardID {
                            let boardTitle = moodboards.boards.first(where: { $0.id == targetBoardID })?.title ?? "活跃情绪板"
                            Task {
                                await moodboards.addAssetsToSpecificBoard(boardID: targetBoardID, assets: items)
                                coordinator.showToast("已加入情绪板「\(boardTitle)」(\(items.count) 项)", icon: "rectangle.3.group")
                            }
                        } else {
                            library.selectedAssetIDs = Set(ids)
                            coordinator.presentMoodboardGenerator(entry: .selection)
                        }
                    },
                    onMoveToFolder: { ids, folderID in
                        Task {
                            await library.moveAssets(ids, toFolderID: folderID)
                            let targetName = folderID.flatMap { fid in library.folders.first(where: { $0.id == fid })?.name } ?? "收件箱"
                            coordinator.showToast("已移动 \(ids.count) 项至「\(targetName)」", icon: "folder")
                        }
                    },
                    onTogglePinOffline: { ids, pinned in
                        Task {
                            await library.togglePinOffline(ids: ids, pinned: pinned)
                            coordinator.showToast(
                                pinned ? "已设为始终保留在本地" : "已取消始终保留，将按需管理空间",
                                icon: pinned ? "arrow.down.circle.fill" : "icloud"
                            )
                        }
                    },
                    onTrashAssets: { ids in
                        Task {
                            await library.trashAssets(ids)
                            coordinator.showToast(
                                "已移至废纸篓 (\(ids.count) 项)",
                                icon: "trash",
                                actionTitle: "撤销",
                                onAction: {
                                    Task {
                                        await library.restoreAssets(ids)
                                        coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward", tone: .success)
                                    }
                                }
                            )
                        }
                    },
                    onRestoreAssets: { ids in
                        Task {
                            await library.restoreAssets(ids)
                            coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward")
                        }
                    }
                )
            } else if coordinator.galleryLayoutMode == .galleryFilmstrip {
                GalleryFilmstripView(
                    assets: library.assets,
                    folders: library.folders,
                    boards: moodboards.boards,
                    activeMoodboardID: coordinator.activeMoodboardID,
                    isQuickLookPresented: coordinator.isModalOverlayPresented || showInboxBatchTriageSheet,
                    loader: library.thumbnailLoader,
                    selectedAssetIDs: Binding(
                        get: { library.selectedAssetIDs },
                        set: { library.selectedAssetIDs = $0 }
                    ),
                    topContentInset: topInset,
                    resolveOriginalURL: { id in
                        try? await library.engine.originalURL(for: id)
                    },
                    onOpenQuickLook: { asset in openQuickLook(asset) },
                    onMarkOpened: { id in library.markAssetOpened(id) },
                    onSetRating: { ids, rating in
                        Task { await library.setRating(rating, for: ids) }
                    },
                    onCopyAssets: { ids in
                        Task {
                            let count = await library.copyAssetsToPasteboard(ids)
                            coordinator.showToast("已拷贝 \(count) 项素材到剪贴板", icon: "doc.on.doc")
                        }
                    },
                    onCutAssets: { ids in
                        Task {
                            let count = await library.cutAssets(ids)
                            coordinator.showToast("已剪切 \(count) 项素材，前往目标文件夹或情绪板按 ⌘V 移动", icon: "scissors")
                        }
                    },
                    onRevealInFinder: { id in
                        Task {
                            let ok = await library.revealInFinder(assetID: id)
                            if !ok {
                                coordinator.showToast("无法定位该素材的本地文件", icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onAddToMoodboard: { ids, boardID in
                        let items = ids.compactMap { library.allAssetsByID[$0] }
                        guard !items.isEmpty else { return }
                        if let targetBoardID = boardID ?? coordinator.activeMoodboardID ?? moodboards.boards.first?.id {
                            let boardTitle = moodboards.boards.first(where: { $0.id == targetBoardID })?.title ?? "活跃情绪板"
                            Task {
                                await moodboards.addAssetsToSpecificBoard(boardID: targetBoardID, assets: items)
                                coordinator.showToast("已加入情绪板「\(boardTitle)」(\(items.count) 项)", icon: "rectangle.3.group")
                            }
                        } else {
                            library.selectedAssetIDs = Set(ids)
                            coordinator.presentMoodboardGenerator(entry: .selection)
                        }
                    },
                    onMoveToFolder: { ids, folderID in
                        Task {
                            await library.moveAssets(ids, toFolderID: folderID)
                            let targetName = folderID.flatMap { fid in library.folders.first(where: { $0.id == fid })?.name } ?? "收件箱"
                            coordinator.showToast("已移动 \(ids.count) 项至「\(targetName)」", icon: "folder")
                        }
                    },
                    onTogglePinOffline: { ids, pinned in
                        Task {
                            await library.togglePinOffline(ids: ids, pinned: pinned)
                            coordinator.showToast(
                                pinned ? "已设为始终保留在本地" : "已取消始终保留，将按需管理空间",
                                icon: pinned ? "arrow.down.circle.fill" : "icloud"
                            )
                        }
                    },
                    onRetagAssets: { ids in
                        triggerAIRetagging(for: ids)
                    },
                    onTrashAssets: { ids in
                        Task {
                            await library.trashAssets(ids)
                            coordinator.showToast(
                                "已移至废纸篓 (\(ids.count) 项)",
                                icon: "trash",
                                actionTitle: "撤销",
                                onAction: {
                                    Task {
                                        await library.restoreAssets(ids)
                                        coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward", tone: .success)
                                    }
                                }
                            )
                        }
                    },
                    onRestoreAssets: { ids in
                        Task {
                            await library.restoreAssets(ids)
                            coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward")
                        }
                    },
                    onPermanentlyDeleteAssets: { ids in
                        pendingPermanentDeleteIDs = ids
                    },
                    onExtractSocialMedia: { postAsset, attachment, idx in
                        Task {
                            if let extracted = await library.extractMediaFromSocialPost(
                                postAsset: postAsset,
                                attachment: attachment,
                                index: idx
                            ) {
                                coordinator.showToast("已单独提取「\(extracted.title)」并保留推文来源", icon: "photo.badge.plus")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onExtractAllSocialMedia: { postAsset in
                        Task {
                            let extracted = await library.extractAllMediaFromSocialPost(postAsset: postAsset)
                            if !extracted.isEmpty {
                                coordinator.showToast("已提取 \(extracted.count) 项推文媒体为独立素材", icon: "square.and.arrow.down.on.square")
                            } else if let err = library.lastError {
                                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onRefreshRichAsset: { id in
                        Task {
                            if await library.refreshRichAsset(id) != nil {
                                coordinator.showToast("已重新拉取最新内容", icon: "arrow.clockwise")
                            }
                        }
                    }
                )
            } else {
                let sideChromeWidth: CGFloat =
                    (isSidebarVisible ? ((coordinator.isSidebarCollapsed ? 76 : 232) + 1) : 0)
                    + (coordinator.isInspectorVisible ? 300 : 0)
                VirtualizedMasonryView(
                    assets: library.assets,
                    assetsRevision: library.assetsRevision,
                    folders: library.folders,
                    loader: library.thumbnailLoader,
                    selectedAssetIDs: Binding(
                        get: { library.selectedAssetIDs },
                        set: { library.selectedAssetIDs = $0 }
                    ),
                    cutAssetIDs: library.cutAssetIDs,
                    layoutMode: coordinator.galleryLayoutMode,
                    targetColumnWidth: CGFloat(coordinator.targetColumnWidth),
                    topContentInset: topInset,
                    bottomContentInset: library.selectedAssetIDs.count >= 2 ? 104 : 44,
                    sideChromeWidth: sideChromeWidth,
                    heroNamespace: heroNamespace,
                    activeQuickLookID: coordinator.quickLookAssetID,
                    revealRequest: coordinator.pendingGalleryReveal,
                    callbacks: MasonryCallbacks(
                        onOpenQuickLook: { asset in openQuickLook(asset) },
                        onDropExternalInputs: { inputs in
                            let folderID: UUID? = if case .folder(let id) = coordinator.selectedDestination { id } else { nil }
                            if inputs.contains(where: { if case .webURL = $0 { true } else { false } }) {
                                coordinator.showToast("正在解析网页缩略图…", icon: "safari")
                            }
                            Task {
                                let created = await library.ingest(inputs, targetFolderID: folderID, targetBoardID: nil)
                                if created.isEmpty {
                                    coordinator.showToast(library.lastError ?? "导入失败或素材已存在", icon: "exclamationmark.triangle", tone: .warning)
                                } else {
                                    coordinator.showToast("已导入 \(created.count) 项素材", icon: "arrow.down.circle.fill", tone: .success)
                                }
                            }
                        },
                        onAddToMoodboard: { ids in
                            if let activeID = coordinator.activeMoodboardID {
                                let items = ids.compactMap { library.allAssetsByID[$0] }
                                Task {
                                    await moodboards.addAssetsToSpecificBoard(boardID: activeID, assets: items)
                                    let title = moodboards.boards.first(where: { $0.id == activeID })?.title ?? "情绪板"
                                    coordinator.showToast("已加入「\(title)」(\(items.count) 项)", icon: "rectangle.3.group")
                                }
                            } else {
                                library.selectedAssetIDs = Set(ids)
                                coordinator.presentMoodboardGenerator(entry: .selection)
                            }
                        },
                        onMoveToFolder: { ids, folderID in
                            Task {
                                await library.moveAssets(ids, toFolderID: folderID)
                                coordinator.showToast("已归档 \(ids.count) 项素材", icon: "folder")
                            }
                        },
                        onTogglePinOffline: { ids, pinned in
                            Task {
                                await library.togglePinOffline(ids: ids, pinned: pinned)
                                coordinator.showToast(
                                    pinned ? "已设为始终保留在本地" : "已取消始终保留，将按需管理空间",
                                    icon: pinned ? "arrow.down.circle.fill" : "icloud"
                                )
                            }
                        },
                        onCopyColorHex: { copyColorHex($0) },
                        onRevealInFinder: { assetID in
                            Task {
                                let ok = await library.revealInFinder(assetID: assetID)
                                if !ok {
                                    coordinator.showToast("无法定位该素材的本地文件", icon: "exclamationmark.triangle", tone: .warning)
                                }
                            }
                        },
                        onCopyAssets: { ids in
                            Task {
                                let count = await library.copyAssetsToPasteboard(ids)
                                coordinator.showToast("已拷贝 \(count) 项素材到剪贴板", icon: "doc.on.doc")
                            }
                        },
                        onCutAssets: { ids in
                            Task {
                                let count = await library.cutAssets(ids)
                                coordinator.showToast("已剪切 \(count) 项素材，前往目标文件夹按 ⌘V 移动", icon: "scissors")
                            }
                        },
                        onPasteIntoCurrentFolder: {
                            pasteIntoCurrentGalleryFolder()
                        },
                        onRetagAssets: { ids in
                            triggerAIRetagging(for: ids)
                        },
                        onTrashAssets: { ids in
                            Task {
                                await library.trashAssets(ids)
                                coordinator.showToast(
                                    "已移至废纸篓 (\(ids.count) 项)",
                                    icon: "trash",
                                    actionTitle: "撤销",
                                    onAction: {
                                        Task {
                                            await library.restoreAssets(ids)
                                            coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward", tone: .success)
                                        }
                                    }
                                )
                            }
                        },
                        onRestoreAssets: { ids in
                            Task {
                                await library.restoreAssets(ids)
                                coordinator.showToast("已将 \(ids.count) 项放回原处", icon: "arrow.uturn.backward")
                            }
                        },
                        onPermanentlyDeleteAssets: { ids in
                            pendingPermanentDeleteIDs = ids
                        },
                        onResolveDragFileURL: { assetID in
                            library.engine.cachedThumbnailURL(for: assetID, tier: .preview1400)
                                ?? library.engine.cachedThumbnailURL(for: assetID, tier: .grid520)
                        },
                        onZoomColumnWidth: { newWidth in
                            let clamped = Double(max(130, min(420, newWidth)))
                            if abs(coordinator.targetColumnWidth - clamped) >= 0.5 {
                                coordinator.targetColumnWidth = clamped
                            }
                        }
                    )
                )
            }

            // Floating Liquid Glass Top Control Stack (Section Context + Max 3 Cohesive Islands + On-Demand Subbar)
            VStack(spacing: 8) {
                floatingTopBar(activeFolderID: activeFolderID, showFolderSubbar: showFolderSubbar)
                    .background {
                        CharkleWindowDragArea()
                            .padding(.top, -10)
                            .padding(.horizontal, -18)
                    }

                if let report = library.semanticSearchReport {
                    semanticSearchStatusBar(report)
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }

                if isInbox && !library.assets.isEmpty {
                    inboxTriageBar
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }

                if isTrash && !library.assets.isEmpty {
                    trashActionBar
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }

                if showFolderSubbar, let activeFolderID {
                    folderSubfoldersBar(folderID: activeFolderID, showInlineBreadcrumb: galleryViewportWidth < 680)
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }
            }
            .padding(.horizontal, galleryViewportWidth < 560 ? 12 : 18)
            .padding(.top, 10)
            .animation(
                CharkleMotion.enterExit(isInbox && !library.assets.isEmpty, reduced: reduceMotion),
                value: isInbox && !library.assets.isEmpty
            )
            .animation(
                CharkleMotion.enterExit(isTrash && !library.assets.isEmpty, reduced: reduceMotion),
                value: isTrash && !library.assets.isEmpty
            )
            .animation(
                CharkleMotion.enterExit(showFolderSubbar, reduced: reduceMotion),
                value: showFolderSubbar
            )

            // Bottom-Center Floating Multi-Select Batch Action Pill (≥2 items selected)
            if library.selectedAssetIDs.count >= 2 {
                VStack {
                    Spacer()
                    multiSelectFloatingActionPill
                        .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .charkleScrollEdgeSoft(for: .top)
        .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: library.selectedAssetIDs.count >= 2)
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            let primaryMods = press.modifiers.intersection([.command, .option, .control, .shift])
            let orderedFolders = library.flattenedFolderHierarchy.map(\.folder)
            guard isInbox, primaryMods.isEmpty,
                  !coordinator.isModalOverlayPresented,
                  !showInboxBatchTriageSheet,
                  !showBatchTagPopover,
                  !showCreateSubfolderPopover,
                  !isEditingText(in: NSApp?.keyWindow),
                  let digit = Int(press.characters),
                  digit >= 1, digit <= orderedFolders.count else { return .ignored }
            let targetFolder = orderedFolders[digit - 1]
            let targetIDs: [UUID] = if !library.selectedAssetIDs.isEmpty {
                Array(library.selectedAssetIDs)
            } else if let first = library.assets.first {
                [first.id]
            } else {
                []
            }
            guard !targetIDs.isEmpty else { return .ignored }
            Task {
                await library.moveAssets(targetIDs, toFolderID: targetFolder.id)
                coordinator.showToast("已快捷键归档至「\(library.folderDisplayPath(for: targetFolder.id))」", icon: "folder.fill")
            }
            return .handled
        }
    }

    // MARK: - Floating Liquid Glass Top Bar (Section Context + Max 3 Cohesive Islands)

    private func floatingTopBar(activeFolderID: UUID?, showFolderSubbar: Bool) -> some View {
        let isUltraCompact = galleryViewportWidth < 600
        let showContextTitle = galleryViewportWidth >= 680
        let supportsDensity = coordinator.galleryLayoutMode == .verticalMasonry || coordinator.galleryLayoutMode == .horizontalJustified
        let showDensitySlider = galleryViewportWidth >= 960 && supportsDensity
        let showFilterText = galleryViewportWidth >= 1180
        let showFullSyncLabel = galleryViewportWidth >= 1280
        let showSortLabel = galleryViewportWidth >= 1320
        let barSpacing: CGFloat = isUltraCompact ? 6 : 8

        return CharkleGlassContainer(spacing: barSpacing) {
            HStack(spacing: barSpacing) {
                if showContextTitle {
                    topContextHeader(
                        activeFolderID: activeFolderID,
                        showInlineSubfolderButton: activeFolderID != nil && !showFolderSubbar
                    )
                    .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                }

                // Island 1: Unified Token Search & Filter Popover
                searchAndFilterIsland(
                    isUltraCompact: isUltraCompact,
                    showFilterText: showFilterText
                )

                // Island 2: View Switcher, Sort & Compact Density
                viewSortDensityIsland(
                    isUltraCompact: isUltraCompact,
                    supportsDensity: supportsDensity,
                    showDensitySlider: showDensitySlider,
                    showSortLabel: showSortLabel
                )

                // Island 3: Moodboard Generator CTA, Isolated Sync Pill & Inspector Toggle
                actionSyncInspectorIsland(
                    isUltraCompact: isUltraCompact,
                    showFullSyncLabel: showFullSyncLabel
                )
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    private var currentDestinationTitle: String {
        switch coordinator.selectedDestination {
        case .allItems: "全部素材"
        case .inbox: "收件箱"
        case .untagged: "未打标签"
        case .recent: "最近添加"
        case .trash: "废纸篓"
        case .moodboardsHome: "所有情绪板"
        case .moodboard(let id):
            moodboards.boards.first(where: { $0.id == id })?.title ?? "情绪板"
        case .folder(let id):
            library.folders.first(where: { $0.id == id })?.name ?? "文件夹"
        case .smartFolder(let id):
            library.smartFolders.first(where: { $0.id == id })?.name ?? "智能文件夹"
        case .tag(let name):
            "#\(name)"
        }
    }

    @ViewBuilder
    private func topContextHeader(activeFolderID: UUID?, showInlineSubfolderButton: Bool) -> some View {
        if let folderID = activeFolderID {
            let crumbs = library.folderBreadcrumbs(for: folderID)

            HStack(spacing: 5) {
                folderBreadcrumbPath(folderID: folderID, crumbs: crumbs)

                Text("\(library.assets.count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    .fixedSize(horizontal: true, vertical: false)

                if showInlineSubfolderButton {
                    Button {
                        subfolderNameDraft = ""
                        showCreateSubfolderPopover = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 24))
                    .help("在此文件夹内新建子文件夹")
                    .popover(isPresented: $showCreateSubfolderPopover, arrowEdge: .bottom) {
                        createSubfolderPopoverContent(parentID: folderID)
                            .environment(\.charkleAccentSource, coordinator.accentSource)
                            .tint(activeAccent)
                    }
                }
            }
            .padding(.leading, 2)
            .help(library.folderDisplayPath(for: folderID))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(currentDestinationTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(library.assets.count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private func folderBreadcrumbPath(folderID: UUID, crumbs: [FolderRecord]) -> some View {
        if let current = crumbs.last {
            if crumbs.count == 1 {
                currentFolderCrumbButton(current, fixedFullWidth: false)
            } else {
                let parent = crumbs[crumbs.count - 2]
                let hiddenAncestors = crumbs.count > 2 ? Array(crumbs.dropLast(2)) : []
                let allAncestors = Array(crumbs.dropLast())

                // Adaptive 3-tier breadcrumb: never crushes ancestor folder names down to clipped half-glyphs.
                ViewThatFits(in: .horizontal) {
                    // Tier 1: Full untruncated path ([… >] Parent > 📁 Current)
                    HStack(spacing: 5) {
                        if !hiddenAncestors.isEmpty {
                            ancestorBreadcrumbMenu(hiddenAncestors)
                            breadcrumbChevron
                        }
                        parentFolderCrumbButton(parent, maxWidth: nil)
                            .fixedSize(horizontal: true, vertical: false)
                        breadcrumbChevron
                        currentFolderCrumbButton(current, fixedFullWidth: true)
                    }

                    // Tier 2: Readable bounded parent (<= 96pt) + generous tail-truncated current folder
                    HStack(spacing: 5) {
                        if !hiddenAncestors.isEmpty {
                            ancestorBreadcrumbMenu(hiddenAncestors)
                            breadcrumbChevron
                        }
                        parentFolderCrumbButton(parent, maxWidth: 96)
                            .layoutPriority(1)
                        breadcrumbChevron
                        currentFolderCrumbButton(current, fixedFullWidth: false)
                            .frame(minWidth: 96, idealWidth: 132, alignment: .leading)
                    }

                    // Tier 3: Narrow fallback — tuck all ancestors into clickable path menu so current title breathes
                    HStack(spacing: 5) {
                        ancestorBreadcrumbMenu(allAncestors)
                        breadcrumbChevron
                        currentFolderCrumbButton(current, fixedFullWidth: false)
                    }
                }
            }
        } else {
            Text(currentDestinationTitle)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var breadcrumbChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    private func ancestorBreadcrumbMenu(_ ancestors: [FolderRecord]) -> some View {
        let fullAncestorPath = ancestors.map(\.name).joined(separator: " / ")
        return Menu {
            ForEach(ancestors) { ancestor in
                Button(ancestor.name) {
                    navigate(to: .folder(ancestor.id))
                }
            }
        } label: {
            Text("…")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                .frame(minWidth: 20, minHeight: 22, maxHeight: 22)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("上级路径：\(fullAncestorPath)")
    }

    private func parentFolderCrumbButton(_ crumb: FolderRecord, maxWidth: CGFloat?) -> some View {
        Button {
            navigate(to: .folder(crumb.id))
        } label: {
            Text(crumb.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func currentFolderCrumbButton(_ crumb: FolderRecord, fixedFullWidth: Bool) -> some View {
        Button {
            navigate(to: .folder(crumb.id))
        } label: {
            HStack(spacing: 5) {
                CharkleFolderIcon(
                    colorHex: crumb.colorHex,
                    customSymbol: crumb.customSymbol,
                    size: 15,
                    isActive: true
                )
                .fixedSize()
                Text(crumb.name)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: fixedFullWidth, vertical: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var activeFilterTokens: [CharkleFilterToken] {
        var tokens: [CharkleFilterToken] = []
        if let hex = library.filter.selectedColorHex {
            tokens.append(.color(hex))
        }
        for kind in MediaKind.allCases where library.filter.kinds.contains(kind) {
            tokens.append(.mediaKind(kind))
        }
        if let shape = library.filter.shape {
            tokens.append(.orientation(shape))
        }
        if library.filter.minRating > 0 {
            tokens.append(.minRating(library.filter.minRating))
        }
        for tag in library.filter.tags.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            tokens.append(.tag(tag))
        }
        if library.filter.onlyPinnedOffline {
            tokens.append(.pinnedOffline)
        }
        return tokens
    }

    private var hasActiveVisualPopoverFilters: Bool {
        !library.filter.kinds.isEmpty
            || library.filter.selectedColorHex != nil
            || library.filter.shape != nil
            || library.filter.minRating > 0
            || library.filter.onlyPinnedOffline
    }

    private func removeFilterToken(_ token: CharkleFilterToken) {
        switch token.kind {
        case .color:
            library.filter.selectedColorHex = nil
        case .mediaKind(let kind):
            library.filter.kinds.remove(kind)
        case .orientation:
            library.filter.shape = nil
        case .minRating:
            library.filter.minRating = 0
        case .tag(let name):
            library.filter.tags.remove(name)
            if case .tag(let destTag) = coordinator.selectedDestination,
               destTag.caseInsensitiveCompare(name) == .orderedSame {
                coordinator.selectedDestination = .allItems
            }
        case .pinnedOffline:
            library.filter.onlyPinnedOffline = false
        }
        Task { await library.refreshAssets() }
    }

    private func clearVisualPopoverFilters() {
        library.filter.kinds.removeAll()
        library.filter.selectedColorHex = nil
        library.filter.shape = nil
        library.filter.minRating = 0
        library.filter.onlyPinnedOffline = false
        Task { await library.refreshAssets() }
    }

    private func searchAndFilterIsland(isUltraCompact: Bool, showFilterText: Bool) -> some View {
        let tokens = activeFilterTokens
        let isFilterActive = coordinator.isVisualFilterBarPresented || hasActiveVisualPopoverFilters

        return CharkleTokenSearchField(
            text: $searchDraft,
            tokens: tokens,
            onRemoveToken: removeFilterToken,
            placeholder: isUltraCompact
                ? (library.semanticSearchEnabled ? "语义搜图…" : "搜索素材…")
                : (library.semanticSearchEnabled ? "描述画面，回车语义搜图…" : "搜索素材、标签、备注或颜色…"),
            semanticSearchEnabled: library.semanticSearchEnabled,
            isRunningSemanticSearch: library.isRunningSemanticSearch,
            showsSemanticToggle: true,
            compact: galleryViewportWidth < 960,
            wrapsInGlassIsland: true,
            onSubmit: {
                let q = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { return }
                if library.semanticSearchEnabled {
                    triggerSemanticSearch()
                }
            },
            onToggleSemanticSearch: {
                let trimmed = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if library.semanticSearchEnabled && trimmed.isEmpty {
                    library.semanticSearchEnabled = false
                    Task { await library.clearSemanticSearch() }
                } else {
                    library.semanticSearchEnabled = true
                    if !trimmed.isEmpty {
                        triggerSemanticSearch()
                    } else {
                        coordinator.showToast("已开启语义搜图模式：输入描述后按回车检索", icon: "sparkles")
                    }
                }
            }
        ) {
            Button {
                coordinator.isVisualFilterBarPresented.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13.5, weight: .medium))
                        .symbolVariant(isFilterActive ? .fill : .none)
                    if showFilterText {
                        Text("筛选")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isFilterActive ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                .padding(.horizontal, showFilterText ? 7 : 5)
                .frame(height: 24)
                .background(
                    isFilterActive
                        ? CharkleTheme.accentSoft(for: colorScheme, source: coordinator.accentSource)
                        : Color.clear,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(CharkleTactileButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .help("色彩、媒体与评分筛选 (⇧⌘S)")
            .popover(
                isPresented: Binding(
                    get: { coordinator.isVisualFilterBarPresented },
                    set: { coordinator.isVisualFilterBarPresented = $0 }
                ),
                arrowEdge: .bottom
            ) {
                visualFilterPopoverContent
                    .environment(\.charkleAccentSource, coordinator.accentSource)
                    .tint(activeAccent)
            }
        }
        .frame(
            minWidth: isUltraCompact ? 110 : 152,
            idealWidth: tokens.isEmpty
                ? (galleryViewportWidth >= 1280 ? 240 : 196)
                : (galleryViewportWidth >= 1280 ? 310 : 240),
            maxWidth: isUltraCompact
                ? .infinity
                : (tokens.isEmpty
                    ? (galleryViewportWidth >= 1320 ? 272 : 224)
                    : (galleryViewportWidth >= 1320 ? 370 : 290))
        )
    }

    private func viewSortDensityIsland(
        isUltraCompact: Bool,
        supportsDensity: Bool,
        showDensitySlider: Bool,
        showSortLabel: Bool
    ) -> some View {
        HStack(spacing: isUltraCompact ? 4 : 6) {
            if isUltraCompact {
                // Ultra-compact (< 600pt): single menu holding layout modes + density steps
                Menu {
                    ForEach(GalleryLayoutMode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                coordinator.galleryLayoutMode = mode
                            }
                        } label: {
                            if coordinator.galleryLayoutMode == mode {
                                Label(mode.localizedLabel, systemImage: "checkmark")
                            } else {
                                Text(mode.localizedLabel)
                            }
                        }
                    }
                    if supportsDensity {
                        Divider()
                        Button("放大卡片") {
                            stepGalleryDensity(direction: 1)
                        }
                        Button("缩小卡片") {
                            stepGalleryDensity(direction: -1)
                        }
                        Button("恢复默认尺寸") {
                            coordinator.targetColumnWidth = 228
                        }
                    }
                } label: {
                    Image(systemName: Self.layoutModeSymbol(for: coordinator.galleryLayoutMode))
                        .font(.system(size: 13, weight: .medium))
                        .symbolVariant(.fill)
                        .foregroundStyle(activeAccent)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换视图与缩放密度（也支持双指捏合或 ⌘+滚轮）")
            } else {
                CharkleSegmentedControl(
                    selection: Binding(
                        get: { coordinator.galleryLayoutMode },
                        set: { coordinator.galleryLayoutMode = $0 }
                    ),
                    options: GalleryLayoutMode.allCases,
                    size: .compact,
                    fullWidth: false,
                    useAccentForSelected: true,
                    systemImage: { Self.layoutModeSymbol(for: $0) },
                    helpText: { Self.layoutModeHelpText(for: $0) }
                )
            }

            CharkleHairlineDivider(axis: .vertical)
                .frame(height: 15)

            // Sort Menu
            Menu {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        library.filter.sortBy = order
                        Task { await library.refreshAssets() }
                    } label: {
                        HStack {
                            Text(order.localizedLabel)
                            if library.filter.sortBy == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                if showSortLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        Text(library.filter.sortBy.localizedLabel)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.88))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                } else {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(showSortLabel ? .automatic : .hidden)
            .fixedSize()
            .help("排序方式：\(library.filter.sortBy.localizedLabel)")

            // Compact Density Control (inline slider >= 840pt; compact menu on 600..<840pt)
            if supportsDensity && !isUltraCompact {
                CharkleHairlineDivider(axis: .vertical)
                    .frame(height: 15)

                if showDensitySlider {
                    HStack(spacing: 4) {
                        Button {
                            stepGalleryDensity(direction: -1)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                .frame(width: 18, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("缩小卡片、显示更多列（也支持双指捏合或 ⌘+滚轮）")

                        Slider(
                            value: Binding(
                                get: { coordinator.targetColumnWidth },
                                set: { coordinator.targetColumnWidth = $0 }
                            ),
                            in: 130...420
                        )
                        .controlSize(.mini)
                        .frame(width: galleryViewportWidth >= 1180 ? 64 : 50)

                        Button {
                            stepGalleryDensity(direction: 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                                .frame(width: 18, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("放大卡片、更清晰浏览细节（也支持双指捏合或 ⌘+滚轮）")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .help("支持触控板双指捏合缩放或按住 ⌘+滚轮缩放")
                } else {
                    Menu {
                        Button("放大卡片") {
                            stepGalleryDensity(direction: 1)
                        }
                        Button("缩小卡片") {
                            stepGalleryDensity(direction: -1)
                        }
                        Divider()
                        Button("恢复默认尺寸") {
                            coordinator.targetColumnWidth = 228
                        }
                    } label: {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("调整卡片密度（也支持双指捏合或 ⌘+滚轮）")
                }
            }
        }
        .padding(.horizontal, isUltraCompact ? 6 : 7)
        .frame(height: 34)
        .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func actionSyncInspectorIsland(isUltraCompact: Bool, showFullSyncLabel: Bool) -> some View {
        let ctaLabel: String? = if galleryViewportWidth >= 1360 {
            "快速生成情绪板"
        } else if galleryViewportWidth >= 1180 {
            "生成情绪板"
        } else if galleryViewportWidth >= 900 {
            "生成"
        } else {
            nil
        }

        return HStack(spacing: isUltraCompact ? 4 : 6) {
            // Rapid Moodboard Generator CTA
            Button {
                coordinator.presentMoodboardGenerator(
                    entry: library.selectedAssetIDs.count >= 2 ? .selection : .prompt
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 13, weight: .medium))
                        .symbolVariant(.fill)
                        .foregroundStyle(activeAccent)
                    if let ctaLabel {
                        Text(ctaLabel)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.90))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, ctaLabel != nil ? 6 : 4)
                .frame(minWidth: 26, minHeight: 24, maxHeight: 24)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(CharkleTactileButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .help("快速生成情绪板 (⌘N)")

            CharkleHairlineDivider(axis: .vertical)
                .frame(height: 15)

            // Isolated Sync Status Pill so 20Hz live sync progress updates never re-render MainWindowView or VirtualizedMasonryView
            FloatingSyncStatusPill(
                syncAndAI: syncAndAI,
                compact: !showFullSyncLabel,
                embeddedInIsland: true,
                onOpenSettings: {
                    let targetTab: CharkleSettingsTab = syncAndAI.syncConfig.mode == .localOnly ? .library : .sync
                    withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                        coordinator.openSettings(tab: targetTab)
                    }
                },
                onTriggerManualSync: triggerManualCloudSync
            )

            CharkleHairlineDivider(axis: .vertical)
                .frame(height: 15)

            // Inspector Toggle
            Button {
                coordinator.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13.5, weight: .medium))
                    .symbolVariant(coordinator.isInspectorVisible ? .fill : .none)
                    .foregroundStyle(coordinator.isInspectorVisible ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                    .frame(width: 26, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(CharkleTactileButtonStyle())
            .help("显示 / 隐藏右侧检查器 (⌘⌥I)")
        }
        .padding(.horizontal, isUltraCompact ? 6 : 8)
        .frame(height: 34)
        .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func stepGalleryDensity(direction: Int) {
        coordinator.targetColumnWidth = Double(MasonryLayoutEngine.steppedColumnWidth(
            currentWidth: CGFloat(coordinator.targetColumnWidth),
            direction: direction,
            layoutMode: coordinator.galleryLayoutMode,
            containerWidth: galleryViewportWidth
        ))
    }

    // MARK: - Lightweight Visual & Color Filter Popover (Replaces Heavy 92pt Stacked Strip)

    private var visualFilterPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("筛选条件")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if hasActiveVisualPopoverFilters {
                    Button("清除全部") {
                        clearVisualPopoverFilters()
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                }
            }

            CharkleHairlineDivider()

            // Color Filter with 10 studio swatches + native NSColorSampler screen eyedropper + HEX + CIELAB tolerance
            CharkleColorFilterPopover(
                selectedColorHex: Binding(
                    get: { library.filter.selectedColorHex },
                    set: { library.filter.selectedColorHex = $0 }
                ),
                colorTolerance: Binding(
                    get: { library.filter.colorTolerance },
                    set: { library.filter.colorTolerance = $0 }
                ),
                title: "主色调",
                embedded: true,
                onSelectColor: { _ in
                    Task { await library.refreshAssets() }
                },
                onToleranceChange: { _ in
                    colorToleranceDebounceTask?.cancel()
                    colorToleranceDebounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        await library.refreshAssets()
                    }
                }
            )

            CharkleHairlineDivider()

            // Media Kinds
            VStack(alignment: .leading, spacing: 7) {
                Text("媒体类型")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))

                CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        let active = library.filter.kinds.contains(kind)
                        Button {
                            if active { library.filter.kinds.remove(kind) }
                            else { library.filter.kinds.insert(kind) }
                            Task { await library.refreshAssets() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: Self.mediaKindSymbol(for: kind))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .symbolVariant(active ? .fill : .none)
                                Text(kind.localizedLabel)
                                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(
                                active
                                    ? CharkleTheme.accentButtonForeground(for: colorScheme, source: coordinator.accentSource)
                                    : Color.primary.opacity(0.84)
                            )
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(
                                active
                                    ? CharkleTheme.accentButtonFill(for: colorScheme, source: coordinator.accentSource)
                                    : CharkleTheme.surfaceSubtle(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                            )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                    }
                }
            }

            CharkleHairlineDivider()

            // Aspect Orientation
            VStack(alignment: .leading, spacing: 7) {
                Text("画幅比例")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))

                HStack(spacing: 6) {
                    ForEach(AspectShape.allCases, id: \.self) { shape in
                        let active = library.filter.shape == shape
                        Button {
                            library.filter.shape = active ? nil : shape
                            Task { await library.refreshAssets() }
                        } label: {
                            Text(shape.localizedLabel)
                                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                .lineLimit(1)
                                .foregroundStyle(
                                    active
                                        ? CharkleTheme.accentButtonForeground(for: colorScheme, source: coordinator.accentSource)
                                        : Color.primary.opacity(0.84)
                                )
                                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                                .background(
                                    active
                                        ? CharkleTheme.accentButtonFill(for: colorScheme, source: coordinator.accentSource)
                                        : CharkleTheme.surfaceSubtle(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                    }
                }
            }

            CharkleHairlineDivider()

            // Minimum Rating + Local Offline Retention
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Text("最低评分")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .padding(.trailing, 3)

                    ForEach(1...5, id: \.self) { star in
                        let filled = star <= library.filter.minRating
                        Button {
                            library.filter.minRating = (library.filter.minRating == star) ? 0 : star
                            Task { await library.refreshAssets() }
                        } label: {
                            Image(systemName: "star")
                                .font(.system(size: 12.5, weight: .medium))
                                .symbolVariant(filled ? .fill : .none)
                                .foregroundStyle(filled ? Color(charkleHex: "#E5B243") : CharkleTheme.secondaryInk(for: colorScheme).opacity(0.55))
                                .frame(width: 20, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("筛选 \(star) 星及以上素材")
                    }
                }

                Spacer(minLength: 6)

                Button {
                    library.filter.onlyPinnedOffline.toggle()
                    Task { await library.refreshAssets() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium))
                            .symbolVariant(library.filter.onlyPinnedOffline ? .fill : .none)
                        Text("本地保留")
                            .font(.system(size: 11.5, weight: library.filter.onlyPinnedOffline ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(library.filter.onlyPinnedOffline ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        library.filter.onlyPinnedOffline
                            ? CharkleTheme.accentSoft(for: colorScheme, source: coordinator.accentSource)
                            : CharkleTheme.surfaceSubtle(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                    )
                }
                .buttonStyle(CharkleTactileButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 336)
    }

    private static func layoutModeSymbol(for mode: GalleryLayoutMode) -> String {
        switch mode {
        case .verticalMasonry: "rectangle.split.3x1"
        case .horizontalJustified: "rectangle.split.1x2"
        case .galleryFilmstrip: "film"
        case .ringGallery: "square.stack.3d.forward.dottedline"
        }
    }

    private static func layoutModeHelpText(for mode: GalleryLayoutMode) -> String {
        switch mode {
        case .verticalMasonry: "纵向瀑布流"
        case .horizontalJustified: "横向等高瀑布流（竖图自动对齐）"
        case .galleryFilmstrip: "画廊视图（底部胶片挑图）"
        case .ringGallery: "环形画廊（3D 外圈景深浏览）"
        }
    }

    private static func mediaKindSymbol(for kind: MediaKind) -> String {
        switch kind {
        case .image: "photo"
        case .animatedImage: "photo.stack"
        case .video: "video"
        case .webBookmark: "globe"
        case .document: "doc.text"
        case .designFile: "square.on.circle"
        case .audio: "waveform"
        case .model3D: "cube"
        }
    }

    // MARK: - Hybrid Semantic Search Status Pill & Inbox Batch Triage Sheet

    private func triggerSemanticSearch() {
        let q = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task {
            if let report = await library.runSemanticSearch(query: q) {
                coordinator.showToast(report.summary, icon: "sparkles")
            } else if let err = library.lastError {
                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
            }
        }
    }

    private func triggerInboxBatchTriage() {
        let targetIDs = library.selectedAssetIDs.isEmpty ? [] : Array(library.selectedAssetIDs)
        Task {
            if let recs = await library.runInboxBatchTriage(assetIDs: targetIDs, maxCount: 24) {
                selectedTriageIDs = Set(
                    recs.filter { $0.recommendedFolderID != nil && $0.confidence >= 0.65 }.map(\.assetID)
                )
                showInboxBatchTriageSheet = true
            } else if let err = library.lastError {
                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
            }
        }
    }

    private func semanticSearchStatusBar(_ report: SemanticSearchReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(activeAccent)
            Text(report.summary)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("返回普通检索") {
                library.semanticSearchEnabled = false
                Task { await library.clearSemanticSearch() }
            }
            .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
    }

    private var inboxBatchTriageSheet: some View {
        let recs = library.inboxTriageRecommendations
        let actionable = recs.filter { $0.recommendedFolderID != nil }
        let selectedRecs = actionable.filter { selectedTriageIDs.contains($0.assetID) }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(activeAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("收件箱智能分拣预览")
                        .font(.system(size: 15, weight: .semibold))
                    Text("共分析 \(recs.count) 项待整理素材，其中 \(actionable.count) 项匹配到已有目录；高置信度项已默认勾选。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if recs.isEmpty {
                Text("收件箱暂无可分拣素材。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 32)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(recs) { rec in
                            let hasTarget = rec.recommendedFolderID != nil
                            let isChecked = selectedTriageIDs.contains(rec.assetID)
                            HStack(spacing: 10) {
                                Button {
                                    guard hasTarget else { return }
                                    if isChecked { selectedTriageIDs.remove(rec.assetID) }
                                    else { selectedTriageIDs.insert(rec.assetID) }
                                } label: {
                                    Image(systemName: !hasTarget ? "minus.circle" : (isChecked ? "checkmark.circle.fill" : "circle"))
                                        .font(.system(size: 16))
                                        .foregroundStyle(!hasTarget ? Color.secondary.opacity(0.45) : (isChecked ? activeAccent : Color.secondary))
                                }
                                .buttonStyle(.plain)
                                .disabled(!hasTarget)

                                if let asset = library.allAssetsByID[rec.assetID] {
                                    AssetThumbnailSurface(
                                        asset: asset,
                                        loader: library.thumbnailLoader,
                                        tier: .grid520,
                                        cornerRadius: 6
                                    )
                                    .frame(width: 44, height: 44)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rec.assetTitle)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(rec.reason)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                if let folderName = rec.recommendedFolderName {
                                    HStack(spacing: 5) {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 10.5))
                                        Text(folderName)
                                            .font(.system(size: 11.5, weight: .semibold))
                                        Text("\(Int((rec.confidence * 100).rounded()))%")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    .foregroundStyle(rec.confidence >= 0.65 ? activeAccent : Color.primary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        rec.confidence >= 0.65
                                            ? CharkleTheme.accentSoft(for: colorScheme, source: coordinator.accentSource)
                                            : Color.primary.opacity(0.08),
                                        in: Capsule(style: .continuous)
                                    )
                                } else {
                                    Text("留在收件箱")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                                }
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .charkleCleanScrollbars(hidden: false)
                }
                .frame(maxHeight: 360)
            }

            HStack {
                if !actionable.isEmpty {
                    Button(selectedRecs.count == actionable.count ? "取消全选" : "全选推荐项") {
                        if selectedRecs.count == actionable.count {
                            selectedTriageIDs.removeAll()
                        } else {
                            selectedTriageIDs = Set(actionable.map(\.assetID))
                        }
                    }
                    .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
                }

                Spacer()

                Button("取消") {
                    showInboxBatchTriageSheet = false
                }
                .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
                .keyboardShortcut(.cancelAction)

                Button("归档已勾选 (\(selectedRecs.count) 项)") {
                    let batch = selectedRecs
                    showInboxBatchTriageSheet = false
                    Task {
                        let moved = await library.applyInboxTriageRecommendations(batch)
                        coordinator.showToast("智能分拣完成：已归档 \(moved) 项素材", icon: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(CharkleButtonStyle(.accent, size: .sm))
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRecs.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    // MARK: - Inbox Triage Bar & Celebratory Empty State

    private var inboxTriageBar: some View {
        let targetIDs: [UUID] = if !library.selectedAssetIDs.isEmpty {
            Array(library.selectedAssetIDs)
        } else if let first = library.assets.first {
            [first.id]
        } else {
            []
        }

        let isNarrowBar = galleryViewportWidth < 620
        return HStack(spacing: isNarrowBar ? 7 : 10) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .symbolVariant(.fill)
                    .foregroundStyle(activeAccent)
                Text(isNarrowBar ? "\(library.inboxCount) 项" : "待整理 \(library.inboxCount) 项")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)

            CharkleHairlineDivider(axis: .vertical).frame(height: 15)

            // AI Suggested Folder 1-Click Pill
            if let suggestion = library.suggestedFolder, !targetIDs.isEmpty {
                Button {
                    Task {
                        await library.moveAssets(targetIDs, toFolderID: suggestion.folderID)
                        coordinator.showToast("已采纳 AI 推荐移入「\(suggestion.folderName)」", icon: "sparkles")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("推荐：\(suggestion.folderName)")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(activeAccent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(CharkleTheme.accentSoft(for: colorScheme, source: coordinator.accentSource), in: Capsule(style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .help(suggestion.reason)
            }

            // Batch Inbox Smart Triage
            if !library.folders.isEmpty {
                Button {
                    triggerInboxBatchTriage()
                } label: {
                    HStack(spacing: 4) {
                        if library.isRunningInboxTriage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(library.isRunningInboxTriage ? "分拣中…" : (isNarrowBar ? "分拣" : "智能分拣"))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(activeAccent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(CharkleTheme.accentSoft(for: colorScheme, source: coordinator.accentSource), in: Capsule(style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .disabled(library.isRunningInboxTriage)
                .help("批量识别收件箱素材并推荐归档目录")
            }

            // Quick 1–9 Folder Archive Chips (in deterministic tree order + full hierarchical menu)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    let orderedNodes = Array(library.flattenedFolderHierarchy.prefix(9))
                    ForEach(Array(orderedNodes.enumerated()), id: \.element.id) { idx, node in
                        let folder = node.folder
                        Button {
                            guard !targetIDs.isEmpty else { return }
                            Task {
                                await library.moveAssets(targetIDs, toFolderID: folder.id)
                                coordinator.showToast("已归档至「\(library.folderDisplayPath(for: folder.id))」", icon: "folder.fill")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                Text(node.depth > 0 ? "↳ \(folder.name)" : folder.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help(library.folderDisplayPath(for: folder.id))
                    }

                    if !library.folders.isEmpty {
                        Menu {
                            CharkleHierarchicalFolderMenuContent(
                                folders: library.folders,
                                includeInbox: false,
                                parentSelfPrefix: "归档至"
                            ) { folderID in
                                guard !targetIDs.isEmpty, let folderID else { return }
                                Task {
                                    await library.moveAssets(targetIDs, toFolderID: folderID)
                                    coordinator.showToast("已归档至「\(library.folderDisplayPath(for: folderID))」", icon: "folder.fill")
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10, weight: .medium))
                                Text("全部目录")
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }

            Spacer(minLength: 4)

            // 1-Click Send to Moodboard
            Menu {
                ForEach(moodboards.boards) { board in
                    Button(board.title) {
                        let items = targetIDs.compactMap { library.allAssetsByID[$0] }
                        Task {
                            await moodboards.addAssetsToSpecificBoard(boardID: board.id, assets: items)
                            coordinator.showToast("已收入情绪板「\(board.title)」", icon: "rectangle.3.group")
                        }
                    }
                }
                Divider()
                Button("用当前收件箱创建新情绪板…") {
                    library.selectedAssetIDs = Set(library.assets.prefix(16).map(\.id))
                    coordinator.presentMoodboardGenerator(entry: .selection)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 12, weight: .medium))
                        .symbolVariant(.fill)
                        .foregroundStyle(activeAccent)
                    Text(isNarrowBar ? "收入板" : "一键收入情绪板")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Trash Recovery & Empty Bar

    private var trashActionBar: some View {
        let allIDs = library.assets.map(\.id)
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("废纸篓 · 共 \(allIDs.count) 项素材")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Button {
                Task {
                    await library.restoreAssets(allIDs)
                    coordinator.showToast("已将 \(allIDs.count) 项全部放回原处", icon: "arrow.uturn.backward")
                }
            } label: {
                Label("全部放回原处", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(CharkleButtonStyle(.standard, size: .xs, cornerRadius: 999))

            Button(role: .destructive) {
                pendingPermanentDeleteIDs = allIDs
            } label: {
                Label("清空废纸篓…", systemImage: "trash.slash")
            }
            .buttonStyle(CharkleButtonStyle(.destructive, size: .xs, cornerRadius: 999))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Folder Subfolders Strip + Click-Outside Popover Creator

    private func folderSubfoldersBar(folderID: UUID, showInlineBreadcrumb: Bool) -> some View {
        let crumbs = library.folderBreadcrumbs(for: folderID)
        let children = library.childFolders(of: folderID)

        return HStack(spacing: 10) {
            if showInlineBreadcrumb {
                // Compact breadcrumb path when top context title is hidden on narrow viewports
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                navigate(to: .folder(crumb.id))
                            } label: {
                                HStack(spacing: 4) {
                                    if index == 0 {
                                        CharkleFolderIcon(colorHex: crumb.colorHex, customSymbol: crumb.customSymbol, size: 15, isActive: true)
                                    }
                                    Text(crumb.name)
                                        .font(.system(size: 12, weight: crumb.id == folderID ? .semibold : .medium))
                                        .foregroundStyle(crumb.id == folderID ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }

            if !children.isEmpty {
                if showInlineBreadcrumb {
                    CharkleHairlineDivider(axis: .vertical).frame(height: 15)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(children) { child in
                            let childCount = library.subtreeAssetCount(for: child.id)
                            Button {
                                navigate(to: .folder(child.id))
                            } label: {
                                HStack(spacing: 5) {
                                    CharkleFolderIcon(colorHex: child.colorHex, customSymbol: child.customSymbol, size: 14, isActive: false)
                                    Text(child.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                    if childCount > 0 {
                                        Text("\(childCount)")
                                            .font(.system(size: 10, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                subfolderNameDraft = ""
                showCreateSubfolderPopover = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                    Text(galleryViewportWidth < 580 ? "新建" : "新建子文件夹")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(activeAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(CharkleTheme.accentSoft(for: colorScheme, source: coordinator.accentSource), in: Capsule(style: .continuous))
            }
            .buttonStyle(CharkleTactileButtonStyle())
            .popover(isPresented: $showCreateSubfolderPopover, arrowEdge: .bottom) {
                createSubfolderPopoverContent(parentID: folderID)
                    .environment(\.charkleAccentSource, coordinator.accentSource)
                    .tint(activeAccent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func createSubfolderPopoverContent(parentID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建子文件夹")
                .font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 6) {
                TextField("子文件夹名称", text: $subfolderNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 190)
                    .focused($isSubfolderFieldFocused)
                    .onSubmit { commitNewSubfolder(parentID: parentID) }
                Button("创建") {
                    commitNewSubfolder(parentID: parentID)
                }
                .buttonStyle(CharkleButtonStyle(.accent, size: .xs))
                .disabled(subfolderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .onAppear {
            DispatchQueue.main.async {
                isSubfolderFieldFocused = true
            }
        }
    }

    private func triggerAIRetagging(for ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if ids.count > 1 {
            coordinator.showToast("正在为 \(ids.count) 项素材重新生成标签…", icon: "sparkles")
        }
        Task {
            let outcome = await library.retagAssetsWithCloudAI(ids: ids)
            switch outcome {
            case .aiDisabled:
                coordinator.showToast("请先在「设置 → 智能与搜索」中开启云端增强智能", icon: "sparkles", tone: .warning)
            case .cancelled(let completed, let total):
                coordinator.showToast("已停止重新打标（已完成 \(completed)/\(total) 项）", icon: "stop.circle")
            case .finished(let succeeded, let failed, let total, let firstError):
                if succeeded > 0 && failed == 0 {
                    coordinator.showToast(
                        total == 1 ? "已按当前格式重新生成建议标签" : "已完成 \(succeeded) 项 AI 重新打标",
                        icon: "sparkles"
                    )
                } else if succeeded > 0 && failed > 0 {
                    coordinator.showToast(
                        "已完成 \(succeeded)/\(total) 项重新打标（\(failed) 项失败）",
                        icon: "exclamationmark.triangle",
                        tone: .warning
                    )
                } else {
                    coordinator.showToast(
                        firstError ?? "重新打标失败，请检查云端增强智能配置",
                        icon: "exclamationmark.triangle",
                        tone: .warning
                    )
                }
            }
        }
    }

    private func commitNewSubfolder(parentID: UUID) {
        let name = subfolderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        subfolderNameDraft = ""
        showCreateSubfolderPopover = false
        Task {
            if let created = await library.createFolder(name: name, parentID: parentID) {
                coordinator.showToast("已创建子文件夹「\(created.name)」", icon: "folder.badge.plus")
            }
        }
    }

    private var inboxZeroCelebrationView: some View {
        InboxZeroCelebrationView(
            onBrowseAll: { navigate(to: .allItems) },
            onGenerateBoard: { coordinator.presentMoodboardGenerator(entry: .prompt) }
        )
    }

    private var emptyLibraryView: some View {
        let isTrash = coordinator.selectedDestination == .trash
        let isFolder: Bool = {
            if case .folder = coordinator.selectedDestination { return true }
            return false
        }()
        let isFiltered = library.filter.hasActiveVisualFilters || !library.filter.searchQuery.isEmpty
        return VStack(spacing: 14) {
            if isTrash && !isFiltered {
                CharkleEmptyStateVignette(.emptyTrash)
                Text("废纸篓是空的")
                    .font(.system(size: 17, weight: .semibold))
                Text("移至废纸篓的素材会暂存在这里，你可以随时放回原处或彻底删除。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                CharkleEmptyStateVignette(
                    isFiltered ? .noFilterResults : (isFolder ? .emptyFolder : .emptyLibrary)
                )
                Text(isFiltered ? "没有符合筛选条件的素材" : (isFolder ? "当前文件夹还没有素材" : "这里还没有素材"))
                    .font(.system(size: 17, weight: .semibold))
                Text("直接拖入图片、GIF、视频、PDF、音频、设计文件或 X / 网页链接，或按 ⌥⇧V 粘贴剪贴板内容。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                HStack(spacing: 10) {
                    if isFiltered {
                        Button("清除筛选条件") {
                            searchDraft = ""
                            library.filter.clearVisualFilters()
                            if case .tag = coordinator.selectedDestination {
                                coordinator.selectedDestination = .allItems
                            }
                            Task { await library.refreshAssets() }
                        }
                        .buttonStyle(CharkleButtonStyle(.standard, size: .md))
                    }
                    Button("采集剪贴板 (⌥⇧V)") { onCollectClipboard() }
                        .buttonStyle(CharkleButtonStyle(.accent, size: .md))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CharkleTheme.galleryGround(for: colorScheme))
    }

    // MARK: - Multi-Select Floating Liquid Glass Batch Action Pill

    private var multiSelectFloatingActionPill: some View {
        let ids = Array(library.selectedAssetIDs)
        let selectedAssets = library.selectedAssets
        let isTrashSelection = coordinator.selectedDestination == .trash
            || (!selectedAssets.isEmpty && selectedAssets.allSatisfy(\.isTrashed))
        let allKeptLocally = !selectedAssets.isEmpty && selectedAssets.allSatisfy(\.pinnedOffline)
        let isCompactPill = galleryViewportWidth < 620

        return CharkleGlassContainer(spacing: isCompactPill ? 6 : 8) {
            HStack(spacing: isCompactPill ? 6 : 8) {
                Text("已选 \(ids.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, 4)

                CharkleHairlineDivider(axis: .vertical).frame(height: 16)

                if isTrashSelection {
                    Button {
                        Task {
                            await library.restoreAssets(ids)
                            coordinator.showToast("已将 \(ids.count) 项放回原处", icon: "arrow.uturn.backward")
                        }
                    } label: {
                        Label("放回原处", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(CharkleButtonStyle(.accent, size: .xs, cornerRadius: 999))

                    Button(role: .destructive) {
                        pendingPermanentDeleteIDs = ids
                    } label: {
                        Label("彻底删除", systemImage: "trash.slash")
                    }
                    .buttonStyle(CharkleButtonStyle(.destructive, size: .xs, cornerRadius: 999))
                } else {
                    Button {
                        Task {
                            if let board = await moodboards.createBoardFromSelection(assetIDs: ids, title: "精选情绪板 (\(ids.count))") {
                                coordinator.openMoodboard(board.id)
                                coordinator.showToast("已用 \(ids.count) 项生成情绪板", icon: "sparkles.rectangle.stack")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 11.5, weight: .semibold))
                                .symbolVariant(.fill)
                            Text(isCompactPill ? "生成板" : "生成情绪板")
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(CharkleButtonStyle(.accent, size: .xs, cornerRadius: 999))

                    Menu {
                        CharkleHierarchicalFolderMenuContent(
                            folders: library.folders,
                            includeInbox: true,
                            parentSelfPrefix: "放入"
                        ) { folderID in
                            Task {
                                await library.moveAssets(ids, toFolderID: folderID)
                                let dest = folderID.map { library.folderDisplayPath(for: $0) } ?? "收件箱"
                                coordinator.showToast("已移动到「\(dest)」", icon: "folder")
                            }
                        }
                    } label: {
                        if isCompactPill {
                            Image(systemName: "folder")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(width: 26, height: 26)
                        } else {
                            Label("移动", systemImage: "folder")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("移动到文件夹")

                    Button {
                        showBatchTagPopover.toggle()
                    } label: {
                        if isCompactPill {
                            Image(systemName: "tag")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(width: 26, height: 26)
                        } else {
                            Label("加标签", systemImage: "tag")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("批量添加标签")
                    .popover(isPresented: $showBatchTagPopover) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("为 \(ids.count) 项素材添加标签")
                                .font(.system(size: 12, weight: .semibold))
                            TextField("输入标签回车…", text: $quickBatchTagDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onSubmit {
                                    let val = quickBatchTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    quickBatchTagDraft = ""
                                    showBatchTagPopover = false
                                    guard !val.isEmpty else { return }
                                    Task {
                                        await library.addTags([val], to: ids)
                                        coordinator.showToast("已为 \(ids.count) 项添加标签 #\(val)", icon: "tag")
                                    }
                                }
                        }
                        .padding(12)
                    }

                    Button {
                        if library.isEnrichingTags {
                            library.cancelRetagging()
                        } else {
                            triggerAIRetagging(for: ids)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if library.isEnrichingTags {
                                ProgressView().controlSize(.mini)
                                Text("\(library.enrichCompletedCount)/\(max(1, library.enrichTotalCount))")
                                    .monospacedDigit()
                            } else if isCompactPill {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .frame(width: 26, height: 26)
                            } else {
                                Image(systemName: "sparkles")
                                Text("AI 打标")
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, isCompactPill && !library.isEnrichingTags ? 0 : 8)
                        .padding(.vertical, isCompactPill && !library.isEnrichingTags ? 0 : 5)
                    }
                    .buttonStyle(.plain)
                    .help(library.isEnrichingTags ? "点击停止批量重新打标" : "按当前语言格式重新生成建议标签并优先合并已有标签")

                    Menu {
                        ForEach(1...5, id: \.self) { star in
                            Button(String(repeating: "★", count: star)) {
                                Task { await library.setRating(star, for: ids) }
                            }
                        }
                        Button("清除评分") { Task { await library.setRating(0, for: ids) } }
                    } label: {
                        if isCompactPill {
                            Image(systemName: "star")
                                .font(.system(size: 12.5, weight: .medium))
                                .frame(width: 26, height: 26)
                        } else {
                            Label("评分", systemImage: "star")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("批量评分")

                    Button {
                        let nextPinned = !allKeptLocally
                        Task {
                            await library.togglePinOffline(ids: ids, pinned: nextPinned)
                            coordinator.showToast(
                                nextPinned ? "已将 \(ids.count) 项设为始终保留在本地" : "已取消 \(ids.count) 项的始终保留",
                                icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13, weight: .medium))
                            .symbolVariant(allKeptLocally ? .fill : .none)
                            .foregroundStyle(allKeptLocally ? activeAccent : Color.primary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(allKeptLocally ? "取消全部保留在本地" : "全部始终保留在本地")

                    Button(role: .destructive) {
                        Task {
                            await library.trashAssets(ids)
                            coordinator.showToast(
                                "已移至废纸篓 (\(ids.count) 项)",
                                icon: "trash",
                                actionTitle: "撤销",
                                onAction: {
                                    Task {
                                        await library.restoreAssets(ids)
                                        coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward", tone: .success)
                                    }
                                }
                            )
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(CharkleTheme.destructive(for: colorScheme))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("移至废纸篓")
                }

                Button {
                    library.selectedAssetIDs.removeAll()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("取消选择 (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
        }
    }

    // MARK: - 2. Moodboards Home Gallery

    private var moodboardsHomeStage: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("情绪板创作台")
                            .font(.system(size: 22, weight: .semibold))
                            .tracking(-0.3)
                        Text("单源引用素材库 · 无限自由画布与智能灵感策展")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            if let blank = await moodboards.createBlankBoard(title: "新情绪板") {
                                coordinator.openMoodboard(blank.id)
                            }
                        }
                    } label: {
                        Text("新建空白板")
                    }
                    .buttonStyle(CharkleButtonStyle(.standard, size: .sm))

                    Button {
                        coordinator.presentMoodboardGenerator(entry: .prompt)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(.system(size: 12.5, weight: .semibold))
                                .symbolVariant(.fill)
                            Text("10 秒快速生成")
                        }
                    }
                    .buttonStyle(CharkleButtonStyle(.accent, size: .sm))
                }

                if moodboards.boards.isEmpty {
                    VStack(spacing: 14) {
                        CharkleEmptyStateVignette(.emptyMoodboard)
                        Text("还没有情绪板")
                            .font(.system(size: 17, weight: .semibold))
                        Text("通过灵感词、种子图、主色板或直接框选素材，10 秒生成首张可编辑情绪板。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        HStack(spacing: 10) {
                            Button("新建空白板") {
                                Task {
                                    if let blank = await moodboards.createBlankBoard(title: "新情绪板") {
                                        coordinator.openMoodboard(blank.id)
                                    }
                                }
                            }
                            .buttonStyle(CharkleButtonStyle(.standard, size: .md))

                            Button("10 秒快速生成") {
                                coordinator.presentMoodboardGenerator(entry: .prompt)
                            }
                            .buttonStyle(CharkleButtonStyle(.accent, size: .md))
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)], spacing: 16) {
                        // Quick Generate Card
                        Button {
                            coordinator.presentMoodboardGenerator(entry: .prompt)
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 28, weight: .medium))
                                    .symbolVariant(.fill)
                                    .foregroundStyle(activeAccent)
                                Text("新建灵感情绪板")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("支持灵感词 / 种子图 / 配色定调 / 框选成板")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 220)
                            .padding(18)
                            .background(
                                CharkleTheme.surfaceElevated(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(activeAccent.opacity(0.35), style: StrokeStyle(lineWidth: 1.25, dash: [6, 5]))
                            )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())

                        ForEach(moodboards.boards) { board in
                            moodboardSummaryCard(board)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .charkleCleanScrollbars(hidden: false)
        }
        .overlay(alignment: .top) {
            CharkleWindowDragArea()
                .frame(height: 24)
        }
        .charkleScrollEdgeSoft(for: .top)
        .background(CharkleTheme.galleryGround(for: colorScheme))
    }

    private func moodboardSummaryCard(_ board: MoodboardSummary) -> some View {
        let isActive = coordinator.activeMoodboardID == board.id
        let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        return Button {
            coordinator.openMoodboard(board.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // 2x2 Preview Mosaic
                let previewIDs = Array(board.previewAssetIDs.prefix(4))
                Group {
                    if previewIDs.isEmpty {
                        ZStack {
                            CharkleTheme.surfaceSubtle(for: colorScheme)
                            Image(systemName: "rectangle.3.group")
                                .font(.system(size: 26, weight: .regular))
                                .foregroundStyle(.secondary.opacity(0.45))
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)], spacing: 3) {
                            ForEach(previewIDs, id: \.self) { id in
                                if let asset = library.allAssetsByID[id] {
                                    AssetThumbnailSurface(
                                        asset: asset,
                                        loader: library.thumbnailLoader,
                                        tier: .grid520,
                                        cornerRadius: 4
                                    )
                                    .frame(height: 64)
                                } else {
                                    CharkleTheme.surfaceSubtle(for: colorScheme).frame(height: 64)
                                }
                            }
                        }
                    }
                }
                .frame(height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Palette Bar
                if !board.paletteHexes.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(board.paletteHexes.prefix(6), id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color(charkleHex: hex))
                                .frame(height: 8)
                        }
                    }
                }

                // Meta Row
                HStack(alignment: .firstTextBaseline) {
                    Text(board.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if isActive {
                        let pos = CharkleTheme.positive(for: colorScheme)
                        Text("活跃板")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(pos)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(pos.opacity(0.12), in: Capsule(style: .continuous))
                    }
                    if board.pinnedOffline {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(activeAccent)
                            .help("已始终保留在本地")
                    }
                }

                HStack {
                    Text("\(board.itemCount) 个节点")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("自由画布")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(board.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(CharkleTheme.surfaceElevated(for: colorScheme), in: cardShape)
            .overlay(cardShape.strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.05), radius: 8, y: 3)
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    // MARK: - 3. Dual-Mode Moodboard Studio Stage

    @ViewBuilder
    private var moodboardStudioStage: some View {
        if let board = moodboards.activeBoard {
            MoodboardCanvasView(
                document: board,
                assetsByID: library.allAssetsByID,
                loader: library.thumbnailLoader,
                swappingNodeID: moodboards.swappingNodeID,
                canUndo: moodboards.canUndo,
                canRedo: moodboards.canRedo,
                isOverlayPresented: coordinator.isModalOverlayPresented || showInboxBatchTriageSheet,
                heroNamespace: heroNamespace,
                callbacks: MoodboardCanvasCallbacks(
                    onCommitDocument: { nextDoc in
                        moodboards.commitMutation(nextDoc)
                    },
                    onPersistViewport: { center, zoom in
                        moodboards.persistViewportQuietly(center: center, zoom: zoom)
                    },
                    onUndo: { moodboards.undo() },
                    onRedo: { moodboards.redo() },
                    onSelectSwapTarget: { nodeID in
                        if nodeID != nil && !coordinator.isInspectorVisible {
                            coordinator.isInspectorVisible = true
                        }
                        Task { await moodboards.selectSwapTarget(nodeID) }
                    },
                    onOpenQuickLook: { asset in
                        if asset.isExternalWebLink, let url = asset.externalWebURL {
                            library.markAssetOpened(asset.id)
                            NSWorkspace.shared.open(url)
                            coordinator.showToast(
                                "已在默认浏览器中打开 \(asset.sourceDomain ?? url.host() ?? "网页")",
                                icon: "safari"
                            )
                            return
                        }
                        if coordinator.quickLookAssetID != nil {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                                coordinator.closeQuickLook()
                            }
                        } else {
                            resignTextFocusIfNeeded()
                            let playlist = board.referencedAssetIDs
                            withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                                coordinator.openQuickLook(assetID: asset.id, playlist: playlist.isEmpty ? [asset.id] : playlist)
                            }
                        }
                    },
                    onRevealInLibrary: { assetID in
                        revealAssetInLibrary(assetID)
                    },
                    onRevealInFinder: { assetID in
                        Task {
                            let ok = await library.revealInFinder(assetID: assetID)
                            if !ok {
                                coordinator.showToast("无法定位该素材的本地文件", icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onCopyAssets: { ids in
                        Task {
                            let count = await library.copyAssetsToPasteboard(ids)
                            coordinator.showToast("已拷贝 \(count) 项素材到剪贴板", icon: "doc.on.doc")
                        }
                    },
                    onCutAssets: { ids in
                        Task {
                            let count = await library.cutAssets(ids)
                            coordinator.showToast("已剪切 \(count) 项素材，可按 ⌘V 粘贴到其他情绪板或文件夹", icon: "scissors")
                        }
                    },
                    onPasteIntoBoard: { dropPoint in
                        let targetBoardID = board.id
                        Task {
                            if let internalPaste = library.internalPasteboardAssets() {
                                let resolved = internalPaste.ids.compactMap { library.allAssetsByID[$0] }
                                guard !resolved.isEmpty else { return }
                                if moodboards.activeBoard?.id == targetBoardID {
                                    await moodboards.appendAssets(resolved, at: dropPoint)
                                } else {
                                    await moodboards.addAssetsToSpecificBoard(boardID: targetBoardID, assets: resolved)
                                }
                                if internalPaste.isCut {
                                    library.clearCutSelection()
                                }
                                coordinator.showToast("已粘贴 \(resolved.count) 项素材到情绪板", icon: "doc.on.clipboard")
                            } else {
                                let inputs = ClipboardCollector.extractInputs(from: .general)
                                guard !inputs.isEmpty else {
                                    coordinator.showToast("剪贴板中没有可粘贴的图片或文件", icon: "doc.on.clipboard", tone: .warning)
                                    return
                                }
                                let created = await library.ingest(inputs, targetFolderID: nil, targetBoardID: nil)
                                guard !created.isEmpty else {
                                    coordinator.showToast(library.lastError ?? "粘贴导入失败", icon: "exclamationmark.triangle", tone: .warning)
                                    return
                                }
                                if moodboards.activeBoard?.id == targetBoardID {
                                    await moodboards.appendAssets(created, at: dropPoint)
                                } else {
                                    await moodboards.addAssetsToSpecificBoard(boardID: targetBoardID, assets: created)
                                }
                                coordinator.showToast("已粘贴导入并加入情绪板 (\(created.count) 项)", icon: "doc.on.clipboard", tone: .success)
                            }
                        }
                    },
                    onDropExternalInputs: { inputs, dropPoint in
                        // Single Source of Truth: new files go into /Charkle/Inbox/ (folderID = nil) and place at dropPoint
                        let targetBoardID = board.id
                        let normalizedInputs = Self.normalizeDroppedCaptureInputs(inputs)
                        Task {
                            let created = await library.ingest(normalizedInputs, targetFolderID: nil, targetBoardID: nil)
                            guard !created.isEmpty else {
                                coordinator.showToast(library.lastError ?? "拖入素材导入失败", icon: "exclamationmark.triangle", tone: .warning)
                                return
                            }
                            if moodboards.activeBoard?.id == targetBoardID {
                                await moodboards.appendAssets(created, at: dropPoint)
                            } else {
                                await moodboards.addAssetsToSpecificBoard(boardID: targetBoardID, assets: created)
                            }
                            coordinator.showToast("已入收件箱并放置在画布 (\(created.count) 项)", icon: "arrow.down.circle.fill", tone: .success)
                        }
                    },
                    onDropLibraryAssetIDs: { ids, dropPoint in
                        let resolved = ids.compactMap { library.allAssetsByID[$0] }
                        Task {
                            await moodboards.appendAssets(resolved, at: dropPoint)
                            coordinator.showToast("已将 \(resolved.count) 项加入画布", icon: "plus.circle.fill")
                        }
                    },
                    onCopyColorHex: { copyColorHex($0) },
                    onSearchByColorHex: { hex in
                        Task {
                            coordinator.selectedDestination = .allItems
                            await library.applyDestination(.allItems)
                            await library.filterByColorHex(hex)
                            coordinator.isVisualFilterBarPresented = true
                        }
                    },
                    onCopyExportedImage: { options in
                        copyCurrentBoardImage(options: options)
                    },
                    onSaveExportedImage: { format, options in
                        saveCurrentBoardImage(format: format, options: options)
                    },
                    onExportFigmaBundle: { options in
                        exportCurrentBoardToFigmaBundle(options: options)
                    },
                    onOpenFigmaPluginGuide: {
                        withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                            coordinator.openSettings(tab: .extensions)
                        }
                    },
                    onSmartFocusNode: { nodeID, assetID, query in
                        let label = query.map { "正在定位「\($0)」…" } ?? "正在识别画面主体…"
                        coordinator.showToast(label, icon: "viewfinder")
                        Task {
                            switch await moodboards.smartFocusNode(nodeID: nodeID, assetID: assetID, query: query) {
                            case .success(let res):
                                coordinator.showToast(
                                    res.summary,
                                    icon: res.found ? "viewfinder" : "questionmark.circle",
                                    tone: res.found ? .neutral : .warning
                                )
                            case .failure(let error):
                                coordinator.showToast(error.localizedDescription, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onVisualMatchCropNode: { nodeID, targetAssetID, referenceAssetID in
                        coordinator.showToast("正在按参考图定位匹配局部…", icon: "photo.on.rectangle.angled")
                        Task {
                            switch await moodboards.visualMatchCropNode(
                                nodeID: nodeID,
                                targetAssetID: targetAssetID,
                                referenceAssetID: referenceAssetID
                            ) {
                            case .success(let res):
                                coordinator.showToast(
                                    res.summary,
                                    icon: res.found ? "photo.on.rectangle.angled" : "questionmark.circle",
                                    tone: res.found ? .neutral : .warning
                                )
                            case .failure(let error):
                                coordinator.showToast(error.localizedDescription, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onCleanCropNode: { nodeID, assetID in
                        coordinator.showToast("正在检测噪边与核心画面…", icon: "crop")
                        Task {
                            switch await moodboards.cleanCropNode(nodeID: nodeID, assetID: assetID) {
                            case .success(let res):
                                coordinator.showToast(res.summary, icon: res.hasNoise ? "crop" : "checkmark.circle")
                            case .failure(let error):
                                coordinator.showToast(error.localizedDescription, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    },
                    onPinpointAnnotateNode: { nodeID, assetID, targetQuery, noteText in
                        coordinator.showToast("正在定位「\(targetQuery)」并生成指物批注…", icon: "scope")
                        Task {
                            let res = await moodboards.pinpointAnnotateNode(
                                nodeID: nodeID,
                                assetID: assetID,
                                targetQuery: targetQuery,
                                noteText: noteText,
                                assetsByID: library.allAssetsByID
                            )
                            switch res {
                            case .success(let region):
                                coordinator.showToast(
                                    region.found ? "已添加指物批注 · \(region.summary)" : region.summary,
                                    icon: region.found ? "scope" : "questionmark.circle",
                                    tone: region.found ? .neutral : .warning
                                )
                            case .failure(let error):
                                coordinator.showToast(error.localizedDescription, icon: "exclamationmark.triangle", tone: .warning)
                            }
                        }
                    }
                )
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    coordinator.isInspectorVisible.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12.5, weight: .medium))
                            .symbolVariant(coordinator.isInspectorVisible ? .fill : .none)
                            .foregroundStyle(coordinator.isInspectorVisible ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                        if galleryViewportWidth >= 520 {
                            Text(coordinator.isInspectorVisible ? "收起候选栏" : "候选替换池")
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, galleryViewportWidth >= 520 ? 10 : 8)
                    .frame(height: 34)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .help(coordinator.isInspectorVisible ? "收起候选栏" : "候选替换池")
                .padding(.top, 10)
                .padding(.trailing, 14)
            }
        } else {
            CharkleBoardLoadingSkeleton()
        }
    }

    // MARK: - Actions & Navigation

    private func navigate(to destination: SidebarDestination) {
        let wasSame = coordinator.selectedDestination == destination
        coordinator.selectedDestination = destination
        switch destination {
        case .moodboard(let id):
            coordinator.activeMoodboardID = id
            // `.onChange(of: coordinator.selectedDestination)` triggers `openBoard(id:)` whenever
            // the destination changes; only trigger directly when re-selecting an unloaded board.
            if wasSame && moodboards.activeBoard?.id != id {
                Task { await moodboards.openBoard(id: id) }
            }
        case .moodboardsHome:
            Task { await moodboards.refreshBoards() }
        default:
            Task { await library.applyDestination(destination) }
        }
    }

    /// Jumps from a Moodboard asset node straight to that asset's actual location in the Library
    /// (folder / inbox / trash), clears blocking search/visual filters if needed, selects & scrolls
    /// directly to the exact card with a spotlight pulse, and offers a 1-click "返回情绪板" toast CTA.
    private func revealAssetInLibrary(_ assetID: UUID) {
        guard let asset = library.allAssetsByID[assetID] else {
            coordinator.showToast("该素材已不在素材库中", icon: "exclamationmark.triangle", tone: .warning)
            return
        }

        let sourceBoardID = moodboards.activeBoard?.id
        coordinator.closeQuickLook()

        let targetDestination: SidebarDestination
        var resolvedLabel: String
        if asset.isTrashed {
            targetDestination = .trash
            resolvedLabel = "废纸篓"
        } else if let folderID = asset.folderID,
                  library.folders.contains(where: { $0.id == folderID }) {
            targetDestination = .folder(folderID)
            resolvedLabel = library.folderDisplayPath(for: folderID)
        } else if asset.folderID == nil {
            targetDestination = .inbox
            resolvedLabel = "收件箱"
        } else {
            targetDestination = .allItems
            resolvedLabel = "全部素材"
        }

        coordinator.selectedDestination = targetDestination

        Task {
            await library.applyDestination(targetDestination)

            if !library.assets.contains(where: { $0.id == assetID }) {
                searchDraft = ""
                library.filter.searchQuery = ""
                library.filter.kinds.removeAll()
                library.filter.selectedColorHex = nil
                library.filter.shape = nil
                library.filter.minRating = 0
                library.filter.onlyPinnedOffline = false
                if library.semanticSearchReport != nil {
                    await library.clearSemanticSearch()
                }
                await library.applyDestination(targetDestination)
            }

            if !library.assets.contains(where: { $0.id == assetID }), targetDestination != .allItems {
                coordinator.selectedDestination = .allItems
                resolvedLabel = "全部素材"
                await library.applyDestination(.allItems)
            }

            library.selectedAssetIDs = [assetID]
            coordinator.requestRevealAssetInGallery(assetID)

            if let sourceBoardID {
                coordinator.showToast(
                    "已定位到「\(resolvedLabel)」",
                    icon: "scope",
                    actionTitle: "返回情绪板",
                    onAction: {
                        navigate(to: .moodboard(sourceBoardID))
                    }
                )
            } else {
                coordinator.showToast("已定位到「\(resolvedLabel)」", icon: "scope")
            }
        }
    }

    private func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSText
    }

    private func isComposingIME(in window: NSWindow?) -> Bool {
        guard let textInput = window?.firstResponder as? any NSTextInputClient else { return false }
        return textInput.hasMarkedText()
    }

    private func resignTextFocusIfNeeded() {
        if let keyWindow = NSApp.keyWindow, isEditingText(in: keyWindow) {
            keyWindow.makeFirstResponder(nil)
        }
    }

    /// Top-priority window-level keyboard coordinator for Overlay `Esc`, Filmstrip/Ring `⌘V`,
    /// and Quick Look `Space` open/close across all views.
    /// Runs before nested stage monitors (Moodboard, Filmstrip, Masonry, AVPlayerView) and ignores Caps Lock / Fn flags.
    private func handleMainWindowKeyDown(_ event: NSEvent, in hostWindow: NSWindow) -> NSEvent? {
        guard hostWindow.attachedSheet == nil, NSApp.modalWindow == nil else { return event }

        let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // 0. Top-down Escape dismissal for ZStack overlays (works even when no SwiftUI descendant has focus)
        if event.keyCode == 53, primaryModifiers.isEmpty, event.window === hostWindow, !isComposingIME(in: hostWindow) {
            if coordinator.isOnboardingPresented {
                if event.isARepeat { return nil }
                resignTextFocusIfNeeded()
                coordinator.showToast("已跳过首次引导 · 随时可在「设置 → 通用」重新查看", icon: "forward.end.fill")
                withAnimation(CharkleMotion.accessible(CharkleMotion.exitMd, reduced: reduceMotion)) {
                    coordinator.completeOnboarding()
                }
                return nil
            }
            if coordinator.isSettingsPresented {
                if event.isARepeat { return nil }
                resignTextFocusIfNeeded()
                withAnimation(CharkleMotion.enterExit(false, enter: CharkleMotion.enterMd, exit: CharkleMotion.exitMd, reduced: reduceMotion)) {
                    coordinator.closeSettings()
                }
                return nil
            }
            if coordinator.isJumpAnywherePresented {
                if event.isARepeat { return nil }
                resignTextFocusIfNeeded()
                coordinator.isJumpAnywherePresented = false
                return nil
            }
        }

        let isInGalleryStage = !coordinator.isViewingMoodboard && coordinator.selectedDestination != .moodboardsHome

        // Support ⌘V paste in Gallery Filmstrip & 3D Ring Gallery (Masonry & Moodboard handle ⌘V directly)
        if primaryModifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "v",
           event.window === hostWindow,
           isInGalleryStage,
           (coordinator.galleryLayoutMode == .galleryFilmstrip || coordinator.galleryLayoutMode == .ringGallery),
           !coordinator.isModalOverlayPresented,
           !showInboxBatchTriageSheet,
           !isEditingText(in: hostWindow) {
            if !event.isARepeat {
                pasteIntoCurrentGalleryFolder()
            }
            return nil
        }

        guard event.keyCode == 49, primaryModifiers.isEmpty else { return event }

        // Never let Space interact with underlying Quick Look or gallery while higher-z overlays are open.
        guard !coordinator.isOnboardingPresented,
              !coordinator.isSettingsPresented,
              !coordinator.isJumpAnywherePresented,
              !coordinator.isMoodboardGeneratorPresented,
              !coordinator.isSmartFolderEditorPresented,
              !showInboxBatchTriageSheet else {
            return event
        }

        // 1. Quick Look is OPEN -> Space closes Quick Look (unless user is actively editing in Quick Look's Inspector)
        if coordinator.quickLookAssetID != nil {
            if isEditingText(in: event.window) || isEditingText(in: hostWindow) {
                return event
            }
            if event.isARepeat { return nil }
            withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                coordinator.closeQuickLook()
            }
            return nil
        }

        // 2. Quick Look is CLOSED -> Only handle events targeted directly at the main window (never popovers/panels)
        guard event.window === hostWindow else { return event }
        guard !isEditingText(in: hostWindow) else { return event }

        // Moodboard Canvas owns Space (Hold = Hand Pan, Quick Tap = Quick Look selected node);
        // Moodboards Home is not a gallery asset list.
        if !isInGalleryStage {
            return event
        }

        if event.isARepeat { return nil }

        // Gallery Filmstrip & Ring Gallery: always preview the selected or currently displayed stage asset
        if coordinator.galleryLayoutMode == .galleryFilmstrip || coordinator.galleryLayoutMode == .ringGallery {
            let target = library.assets.first(where: { library.selectedAssetIDs.contains($0.id) })
                ?? library.assets.first
            if let asset = target {
                openQuickLook(asset)
                return nil
            }
            return event
        }

        // Vertical Masonry / Horizontal Justified: open Quick Look for selected asset regardless of focus pane
        if !library.selectedAssetIDs.isEmpty {
            let target = library.assets.first(where: { library.selectedAssetIDs.contains($0.id) })
                ?? library.selectedAssetIDs.first.flatMap { library.allAssetsByID[$0] }
            if let asset = target {
                openQuickLook(asset)
                return nil
            }
        }
        return event
    }

    private func pasteIntoCurrentGalleryFolder() {
        let targetFolderID: UUID? = if case .folder(let id) = coordinator.selectedDestination { id } else { nil }
        if library.internalPasteboardAssets()?.isCut == true {
            Task {
                let moved = await library.pasteCutAssets(toFolderID: targetFolderID)
                let destName = targetFolderID.map { library.folderDisplayPath(for: $0) } ?? "收件箱"
                coordinator.showToast("已移动 \(moved) 项素材至「\(destName)」", icon: "folder")
            }
        } else {
            let inputs = ClipboardCollector.extractInputs(from: .general)
            guard !inputs.isEmpty else { return }
            let hasWebURL = inputs.contains { if case .webURL = $0 { true } else { false } }
            if hasWebURL {
                coordinator.showToast("正在解析网页缩略图…", icon: "safari")
            }
            Task {
                let created = await library.ingest(inputs, targetFolderID: targetFolderID, targetBoardID: nil)
                guard !created.isEmpty else {
                    coordinator.showToast(library.lastError ?? "粘贴导入失败或素材已存在", icon: "exclamationmark.triangle", tone: .warning)
                    return
                }
                coordinator.showToast(
                    hasWebURL
                        ? "已收藏网页书签 (\(created.count) 项)"
                        : "已粘贴导入 \(created.count) 项素材",
                    icon: hasWebURL ? "safari" : "doc.on.clipboard",
                    tone: .success
                )
            }
        }
    }

    private static func normalizeDroppedCaptureInputs(_ inputs: [CaptureInput]) -> [CaptureInput] {
        inputs.map { input in
            guard case .imageData(let data, let suggestedName, let sourceURL) = input else {
                return input
            }
            let ext = detectedImageExtension(for: data)
            let stem = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
            let base = stem.isEmpty ? "CanvasDrop" : stem
            let uniqueName = "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
            return .imageData(data, suggestedName: uniqueName, sourceURL: sourceURL)
        }
    }

    private static func detectedImageExtension(for data: Data) -> String {
        let bytes = Array(data.prefix(12))
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }
        if bytes.count >= 6, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
            return "gif"
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "webp"
        }
        if bytes.count >= 4,
           ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)) {
            return "tiff"
        }
        return "png"
    }

    private func openQuickLook(_ asset: AssetRecord) {
        if asset.isExternalWebLink, let url = asset.externalWebURL {
            library.markAssetOpened(asset.id)
            NSWorkspace.shared.open(url)
            coordinator.showToast(
                "已在默认浏览器中打开 \(asset.sourceDomain ?? url.host() ?? "网页")",
                icon: "safari"
            )
            return
        }
        resignTextFocusIfNeeded()
        let playlist = library.assets.map(\.id)
        withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
            coordinator.openQuickLook(assetID: asset.id, playlist: playlist.isEmpty ? [asset.id] : playlist)
        }
    }

    private func copyColorHex(_ hex: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hex.uppercased(), forType: .string)
        coordinator.showToast("已复制色值 \(hex.uppercased())", icon: "eyedropper")
    }

    private func copyCurrentBoardImage(options: MoodboardExportOptions) {
        guard let board = moodboards.activeBoard else { return }
        let ok = MoodboardExporter.copyToPasteboard(
            document: board,
            assetsByID: library.allAssetsByID,
            loader: library.thumbnailLoader,
            options: options
        )
        coordinator.showToast(
            ok ? "已复制 2× 高清情绪板（可直接 ⌘V 到 Figma）" : "导出失败",
            icon: ok ? "doc.on.clipboard.fill" : "exclamationmark.triangle",
            tone: ok ? .success : .error
        )
    }

    private func saveCurrentBoardImage(format: MoodboardExportFormat, options: MoodboardExportOptions) {
        guard let board = moodboards.activeBoard else { return }
        let panel = NSSavePanel()
        panel.title = "导出高清情绪板"
        panel.nameFieldStringValue = "\(board.title).\(format.fileExtension)"
        panel.allowedContentTypes = format == .png ? [.png] : [.jpeg]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try MoodboardExporter.exportToFile(
                    document: board,
                    assetsByID: library.allAssetsByID,
                    loader: library.thumbnailLoader,
                    url: url,
                    format: format,
                    options: options
                )
                coordinator.showToast("已导出 2× 图片至 \(url.lastPathComponent)", icon: "checkmark.circle.fill", tone: .success)
            } catch {
                coordinator.showToast("导出失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", tone: .error)
            }
        }
    }

    private func exportCurrentBoardToFigmaBundle(options: MoodboardExportOptions) {
        guard let board = moodboards.activeBoard else { return }
        let panel = NSSavePanel()
        panel.title = "导出到 Figma / FigJam（可编辑独立图层）"
        panel.message = "保存为 .charkleboard 文件后，在 Figma / FigJam 中运行「Charkle → Figma Bridge」插件导入，即可保留独立图片、原图像素、便签、分组、色卡与连线。"
        let safeTitle = board.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Charkle情绪板" : board.title
        panel.nameFieldStringValue = "\(safeTitle).charkleboard"
        panel.allowedContentTypes = [UTType(filenameExtension: "charkleboard") ?? .zip]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let targetURL = url.pathExtension.isEmpty ? url.appendingPathExtension("charkleboard") : url
        let assetsSnapshot = library.allAssetsByID
        let engine = library.engine
        coordinator.showToast("正在打包可编辑 Figma 情绪板…", icon: "square.stack.3d.up")

        Task {
            do {
                let report = try await FigmaBridgeExporter.exportBundle(
                    document: board,
                    assetsByID: assetsSnapshot,
                    options: options,
                    resolveOriginalURL: { id in try? await engine.originalURL(for: id) },
                    resolveThumbnailURL: { id, tier in await engine.thumbnailURL(for: id, tier: tier) },
                    to: targetURL
                )
                NSWorkspace.shared.activateFileViewerSelecting([report.bundleURL])
                coordinator.showToast(
                    "已导出 \(report.objectCount) 个可编辑对象至 \(report.bundleURL.lastPathComponent)",
                    icon: "checkmark.circle.fill",
                    tone: .success
                )
            } catch {
                coordinator.showToast("导出 Figma 包失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", tone: .error)
            }
        }
    }

    private func handleJumpMatch(_ match: QuickJumpMatch) {
        switch match.kind {
        case .moodboard:
            if let id = match.targetUUID { navigate(to: .moodboard(id)) }
        case .folder:
            if let id = match.targetUUID { navigate(to: .folder(id)) }
        case .tag:
            if let tag = match.tagName { navigate(to: .tag(tag)) }
        case .asset:
            if let id = match.targetUUID {
                coordinator.selectedDestination = .allItems
                Task {
                    await library.applyDestination(.allItems)
                    library.selectedAssetIDs = [id]
                    coordinator.requestRevealAssetInGallery(id)
                    if let asset = library.allAssetsByID[id] ?? library.assets.first(where: { $0.id == id }) {
                        openQuickLook(asset)
                    }
                }
            }
        }
    }

    private func handleQuickCommand(_ cmd: JumpAnywhereView.QuickCommand) {
        switch cmd {
        case .newMoodboard: coordinator.presentMoodboardGenerator(entry: .prompt)
        case .openInbox: navigate(to: .inbox)
        case .toggleNotch: onToggleNotch()
        case .captureArea: onCaptureArea()
        }
    }

    private func triggerManualCloudSync() {
        Task {
            if let report = await syncAndAI.syncNow() {
                await library.refreshAll()
                await moodboards.refreshBoards()
                coordinator.showToast(
                    "同步完成 · 上传 \(report.uploadedOps) / 拉取 \(report.downloadedOps) / 新发现 \(report.discoveredRemoteAssets)",
                    icon: "checkmark.icloud.fill"
                )
            } else if let err = syncAndAI.errorMessage {
                coordinator.showToast(err, icon: "exclamationmark.icloud", tone: .warning)
            }
        }
    }
}

/// Isolated top-bar sync pill & progress popover so frequent live sync progress broadcasts
/// update only this compact control rather than triggering full Gallery / MainWindowView diffs.
private struct FloatingSyncStatusPill: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource

    let syncAndAI: SyncAndAIStore
    var compact: Bool = false
    var embeddedInIsland: Bool = true
    let onOpenSettings: () -> Void
    let onTriggerManualSync: () -> Void

    @State private var showSyncPopover: Bool = false

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    var body: some View {
        Button {
            if syncAndAI.syncConfig.mode == .localOnly {
                onOpenSettings()
            } else {
                showSyncPopover.toggle()
                if showSyncPopover {
                    Task { await syncAndAI.refreshSyncStatus() }
                }
            }
        } label: {
            if embeddedInIsland {
                if compact {
                    ZStack {
                        if syncAndAI.syncStatus.isSyncing || syncAndAI.isBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(syncDotColor)
                                .frame(width: 7.5, height: 7.5)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                } else {
                    HStack(spacing: 5) {
                        if syncAndAI.syncStatus.isSyncing || syncAndAI.isBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(syncDotColor)
                                .frame(width: 7, height: 7)
                        }
                        Text(syncPillLabel)
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary.opacity(0.88))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 5)
                    .frame(height: 24)
                    .contentShape(Capsule(style: .continuous))
                }
            } else if compact {
                ZStack {
                    if syncAndAI.syncStatus.isSyncing || syncAndAI.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle()
                            .fill(syncDotColor)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 30, height: 30)
                .charkleLiquidGlass(.regular, in: Circle(), interactive: true)
            } else {
                HStack(spacing: 5) {
                    if syncAndAI.syncStatus.isSyncing || syncAndAI.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle()
                            .fill(syncDotColor)
                            .frame(width: 7, height: 7)
                    }
                    Text(syncPillLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
            }
        }
        .buttonStyle(CharkleTactileButtonStyle())
        .popover(isPresented: $showSyncPopover, arrowEdge: .bottom) {
            cloudSyncProgressPopover
                .environment(\.charkleAccentSource, accentSource)
                .tint(activeAccent)
        }
        .contextMenu {
            if syncAndAI.syncConfig.mode != .localOnly {
                Button("立即同步") {
                    onTriggerManualSync()
                }
                Divider()
            }
            Button("打开存储与同步设置…") { onOpenSettings() }
        }
        .help(syncAndAI.syncConfig.mode == .localOnly ? "\(syncPillLabel) · 点击打开存储设置" : "\(syncPillLabel) · 点击查看云端同步进度与状态")
    }

    private var syncDotColor: Color {
        switch syncAndAI.syncStatus.phase {
        case .error: return CharkleTheme.destructive(for: colorScheme)
        case .scanning, .uploading, .downloading, .merging: return CharkleTheme.warning(for: colorScheme)
        case .idle:
            if syncAndAI.syncConfig.mode == .localOnly { return CharkleTheme.secondaryInk(for: colorScheme) }
            return syncAndAI.syncStatus.pendingOpCount > 0 ? CharkleTheme.warning(for: colorScheme) : CharkleTheme.positive(for: colorScheme)
        }
    }

    private var syncPillLabel: String {
        let status = syncAndAI.syncStatus
        let pctSuffix = status.progressFraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
        switch status.phase {
        case .scanning:
            return "扫描中\(pctSuffix)"
        case .uploading(let done, let total):
            return total > 0 ? "上传 \(done)/\(total)" : "上传中\(pctSuffix)"
        case .downloading(let done, let total):
            return total > 0 ? "拉取 \(done)/\(total)" : "拉取中\(pctSuffix)"
        case .merging:
            return "整理中\(pctSuffix)"
        case .error:
            return "同步异常"
        case .idle:
            if syncAndAI.isBusy { return "同步中…" }
            let pendingSuffix = status.pendingOpCount > 0 ? " · 待传 \(status.pendingOpCount)" : ""
            switch syncAndAI.syncConfig.mode {
            case .localOnly: return "本地保存"
            case .directAPIWithGDirect: return "Google Drive\(pendingSuffix)"
            case .webDAV: return "WebDAV\(pendingSuffix)"
            case .gdirectMount: return "Drive 挂载\(pendingSuffix)"
            }
        }
    }

    private var cloudSyncProgressPopover: some View {
        let status = syncAndAI.syncStatus
        let isSyncing = status.isSyncing || syncAndAI.isBusy
        let percentText = status.progressFraction.map { "\(Int(($0 * 100).rounded()))%" }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(syncDotColor)
                        .frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isSyncing ? status.localizedPhaseTitle : (status.pendingOpCount > 0 ? "有 \(status.pendingOpCount) 项待同步" : "云端存储已连接"))
                            .font(.system(size: 13, weight: .semibold))
                        if isSyncing, let percentText {
                            Text(percentText)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(activeAccent)
                        }
                    }
                    Text(syncAndAI.syncConfig.activeStorageLocationSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if isSyncing {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = status.progressFraction {
                        ProgressView(value: min(1.0, max(0.0, fraction)))
                            .progressViewStyle(.linear)
                            .tint(activeAccent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(activeAccent)
                    }
                    if let detail = status.currentDetail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else if let err = status.lastError, !err.isEmpty {
                let errColor = CharkleTheme.destructive(for: colorScheme)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(errColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(errColor.opacity(0.08), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("上次同步")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(status.lastSyncedAt.map { formatRelativeSyncTime($0) } ?? "尚未同步")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                HStack {
                    Text("本地待传队列")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(status.pendingOpCount > 0 ? "\(status.pendingOpCount) 项" : "已清空")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(status.pendingOpCount > 0 ? CharkleTheme.warning(for: colorScheme) : .secondary)
                }
                if let report = syncAndAI.lastSyncReport {
                    HStack {
                        Text("最近同步结果")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("↑ \(report.uploadedOps)  ↓ \(report.downloadedOps)  +\(report.discoveredRemoteAssets)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                    }
                }
            }
            .padding(9)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    onTriggerManualSync()
                } label: {
                    Text(isSyncing ? "同步中…" : "立即同步")
                }
                .buttonStyle(CharkleButtonStyle(.accent, size: .sm, fullWidth: true))
                .disabled(isSyncing)

                Button("存储设置…") {
                    showSyncPopover = false
                    onOpenSettings()
                }
                .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
            }
        }
        .padding(14)
        .frame(width: 296)
    }

    private func formatRelativeSyncTime(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 15 { return "刚刚" }
        if elapsed < 60 { return "\(Int(elapsed)) 秒前" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

/// Rare Inbox Zero completion surface (Delight tier): stepped `enterMd` icon scale + `45ms`
/// delayed `settleStrong` copy/CTA reveal, non-blocking and degrading to a 150ms fade under Reduce Motion.
private struct InboxZeroCelebrationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onBrowseAll: () -> Void
    let onGenerateBoard: () -> Void

    @State private var appeared: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            CharkleEmptyStateVignette(.inboxZero)
                .scaleEffect(appeared ? 1.0 : (reduceMotion ? 1.0 : 0.94))
                .opacity(appeared ? 1.0 : 0.0)
                .animation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion), value: appeared)

            VStack(spacing: 14) {
                Text("收件箱已清空")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.2)
                Text("所有灵感都已妥善归档或进入情绪板。随时拖动文件到 MacBook 刘海或按 ⌥⇧A 截图采集。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    Button("浏览全部素材", action: onBrowseAll)
                        .buttonStyle(CharkleButtonStyle(.standard, size: .md))
                    Button("10 秒生成情绪板", action: onGenerateBoard)
                        .buttonStyle(CharkleButtonStyle(.accent, size: .md))
                }
                .padding(.top, 4)
            }
            .offset(y: appeared ? 0 : (reduceMotion ? 0 : 8))
            .opacity(appeared ? 1.0 : 0.0)
            .animation(
                reduceMotion
                    ? CharkleMotion.reducedMotionFade
                    : CharkleMotion.settleStrong.delay(0.045),
                value: appeared
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CharkleTheme.galleryGround(for: colorScheme))
        .onAppear {
            appeared = true
        }
    }
}

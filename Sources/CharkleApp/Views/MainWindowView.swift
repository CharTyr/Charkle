import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Gallery-First primary window shell with restrained Apple Liquid Glass floating controls,
/// soft scroll edge fade, expandable visual/CIELAB filter bar, Inbox Triage bar, Moodboards Home,
/// Dual-Mode Moodboard Studio, adaptive Inspector, Quick Look continuity, and Jump Anywhere.
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
    public let onAppReady: () -> Void

    @Namespace private var heroNamespace

    @State private var searchDraft: String = ""
    @State private var isSidebarVisible: Bool = true
    @State private var quickBatchTagDraft: String = ""
    @State private var showBatchTagPopover: Bool = false
    @State private var pendingPermanentDeleteIDs: [UUID] = []
    @State private var showCreateSubfolderPopover: Bool = false
    @State private var subfolderNameDraft: String = ""
    @State private var showInboxBatchTriageSheet: Bool = false
    @State private var selectedTriageIDs: Set<UUID> = []
    @FocusState private var isSubfolderFieldFocused: Bool

    private static let filterColorPresets: [String] = [
        "#1E2024", "#5C6B73", "#3D5A80", "#4E7D96",
        "#6B8E76", "#D4A373", "#BA6B55", "#E5B243",
        "#C8B8A6", "#F0EEE9"
    ]

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
        self.onAppReady = onAppReady
    }

    public var body: some View {
        ZStack {
            // Native 3-pane studio layout (avoids macOS 26/27 NavigationSplitView + hiddenTitleBar
            // ScrollView safe-area hit-test vertical offset bug, ensuring 0px-accurate sidebar clicks).
            // Sidebar and Inspector keep deterministic fixed internal widths inside animated width slots
            // so rapid collapse/expand cycles never get stuck half-open or overflow past window bounds.
            HStack(spacing: 0) {
                let sidebarTargetWidth: CGFloat = coordinator.isSidebarCollapsed ? 56 : 232
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
                                let targetName = folderID.flatMap { fid in library.folders.first(where: { $0.id == fid })?.name } ?? "收件箱"
                                coordinator.showToast("已移动 \(ids.count) 项到「\(targetName)」", icon: "folder")
                            }
                        },
                        onDropExternalOntoFolder: { inputs, folderID in
                            Task {
                                let created = await library.ingest(inputs, targetFolderID: folderID, targetBoardID: nil)
                                coordinator.showToast("已导入 \(max(created.count, inputs.count)) 项素材", icon: "arrow.down.circle.fill")
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
                                await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                                await moodboards.refreshBoards()
                                coordinator.showToast("已收入并上板 (\(max(created.count, inputs.count)) 项)", icon: "sparkles.rectangle.stack")
                            }
                        }
                    )
                    .frame(width: sidebarTargetWidth)
                    .background {
                        CharkleSidebarMaterialBackground()
                            .ignoresSafeArea(.container, edges: .top)
                    }

                    Rectangle()
                        .fill(CharkleTheme.hairline(for: colorScheme))
                        .frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .frame(width: sidebarTargetWidth + 1)
                .frame(maxHeight: .infinity)
                .opacity(isSidebarVisible ? 1 : 0)
                .allowsHitTesting(isSidebarVisible)
                .disabled(!isSidebarVisible)
                .accessibilityHidden(!isSidebarVisible)
                .frame(width: isSidebarVisible ? (sidebarTargetWidth + 1) : 0, alignment: .trailing)
                .clipped()
                .layoutPriority(1)

                centerWorkspace
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxHeight: .infinity)
                .opacity(coordinator.isInspectorVisible ? 1 : 0)
                .allowsHitTesting(coordinator.isInspectorVisible)
                .disabled(!coordinator.isInspectorVisible)
                .accessibilityHidden(!coordinator.isInspectorVisible)
                .frame(width: coordinator.isInspectorVisible ? 300 : 0, alignment: .leading)
                .clipped()
                .layoutPriority(1)
            }
            .animation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion), value: isSidebarVisible)
            .animation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion), value: coordinator.isSidebarCollapsed)
            .animation(CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion), value: coordinator.isInspectorVisible)

            // Full-Media Quick Look Hero Continuity Overlay (Kubai Tip 015)
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
                    }
                )
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

            // Centered Refto-Inspired Settings Overlay (⌘, or bottom-left sidebar gear)
            if coordinator.isSettingsPresented {
                SettingsOverlayView(
                    coordinator: coordinator,
                    library: library,
                    syncAndAI: syncAndAI,
                    onToggleNotchPreview: onToggleNotch,
                    onSyncHotkeysEnabled: onSyncHotkeysEnabled,
                    onSyncDefaultNotchTarget: onSyncDefaultNotchTarget,
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

            // Floating Toasts (Top-Trailing, Kubai Tip 011 enterSm / exitSm)
            VStack {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(coordinator.toasts) { toast in
                            HStack(spacing: 8) {
                                Image(systemName: toast.iconName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(toastTint(toast.tone))
                                Text(toast.message)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .top)),
                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                )
                            )
                        }
                    }
                    .padding(.top, 16)
                    .padding(.trailing, 20)
                }
                Spacer()
            }
            .allowsHitTesting(false)
            .zIndex(300)
            .animation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion), value: coordinator.toasts)
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
        }
        .sheet(isPresented: $showInboxBatchTriageSheet) {
            inboxBatchTriageSheet
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
            library.filter.searchQuery = newValue
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                library.semanticSearchReport = nil
                Task { await library.refreshAssets() }
            } else if !library.semanticSearchEnabled {
                library.semanticSearchReport = nil
                Task { await library.refreshAssets() }
            }
        }
        .onChange(of: coordinator.selectedDestination) { _, newDest in
            if case .moodboard(let id) = newDest {
                coordinator.activeMoodboardID = id
                Task { await moodboards.openBoard(id: id) }
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

    // MARK: - 1. Library Gallery Stage (Floating Liquid Glass Top Bar + Filter Bar + Inbox Triage + Virtualized Masonry)

    private var libraryGalleryStage: some View {
        let isInbox = coordinator.selectedDestination == .inbox
        let isTrash = coordinator.selectedDestination == .trash
        let activeFolderID: UUID? = if case .folder(let fid) = coordinator.selectedDestination { fid } else { nil }
        let topInset: CGFloat = {
            var base: CGFloat = 74
            if library.semanticSearchReport != nil { base += 46 }
            if coordinator.isVisualFilterBarPresented { base += 92 }
            if isInbox && !library.assets.isEmpty { base += 54 }
            if isTrash && !library.assets.isEmpty { base += 54 }
            if activeFolderID != nil { base += 54 }
            return base
        }()

        return ZStack(alignment: .top) {
            if isInbox && library.assets.isEmpty && !library.isLoading && !library.filter.hasActiveVisualFilters && library.filter.searchQuery.isEmpty {
                inboxZeroCelebrationView
            } else if library.assets.isEmpty && !library.isLoading {
                emptyLibraryView
            } else if coordinator.galleryLayoutMode == .galleryFilmstrip {
                GalleryFilmstripView(
                    assets: library.assets,
                    folders: library.folders,
                    boards: moodboards.boards,
                    activeMoodboardID: coordinator.activeMoodboardID,
                    isQuickLookPresented: coordinator.quickLookAssetID != nil,
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
                            coordinator.showToast("已移至废纸篓 (\(ids.count) 项)", icon: "trash")
                        }
                    },
                    onRestoreAssets: { ids in
                        Task {
                            await library.restoreAssets(ids)
                            coordinator.showToast("已放回原处 (\(ids.count) 项)", icon: "arrow.uturn.backward")
                        }
                    },
                    onPermanentlyDeleteAssets: { ids in
                        Task {
                            await library.permanentlyDeleteAssets(ids)
                            coordinator.showToast("已彻底删除 \(ids.count) 项素材", icon: "trash.slash")
                        }
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
                    heroNamespace: heroNamespace,
                    activeQuickLookID: coordinator.quickLookAssetID,
                    callbacks: MasonryCallbacks(
                        onOpenQuickLook: { asset in openQuickLook(asset) },
                        onDropExternalInputs: { inputs in
                            let folderID: UUID? = if case .folder(let id) = coordinator.selectedDestination { id } else { nil }
                            Task {
                                let created = await library.ingest(inputs, targetFolderID: folderID, targetBoardID: nil)
                                coordinator.showToast("已导入 \(max(created.count, inputs.count)) 项素材", icon: "arrow.down.circle.fill")
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
                                Task {
                                    let created = await library.ingest(inputs, targetFolderID: targetFolderID, targetBoardID: nil)
                                    coordinator.showToast("已粘贴导入 \(max(created.count, inputs.count)) 项素材", icon: "doc.on.clipboard")
                                }
                            }
                        },
                        onRetagAssets: { ids in
                            triggerAIRetagging(for: ids)
                        },
                        onTrashAssets: { ids in
                            Task {
                                await library.trashAssets(ids)
                                coordinator.showToast("已移至废纸篓", icon: "trash")
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

            // Floating Liquid Glass Top Control Stack
            VStack(spacing: 8) {
                floatingTopBar

                if let report = library.semanticSearchReport {
                    semanticSearchStatusBar(report)
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }

                if coordinator.isVisualFilterBarPresented {
                    floatingVisualFilterBar
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.96, reduced: reduceMotion))
                }

                if isInbox && !library.assets.isEmpty {
                    inboxTriageBar
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }

                if isTrash && !library.assets.isEmpty {
                    trashActionBar
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }

                if let activeFolderID {
                    folderSubfoldersBar(folderID: activeFolderID)
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.98, reduced: reduceMotion))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .animation(
                CharkleMotion.enterExit(
                    coordinator.isVisualFilterBarPresented,
                    enter: CharkleMotion.popoverEnter,
                    exit: CharkleMotion.popoverExit,
                    reduced: reduceMotion
                ),
                value: coordinator.isVisualFilterBarPresented
            )
            .animation(
                CharkleMotion.enterExit(isInbox && !library.assets.isEmpty, reduced: reduceMotion),
                value: isInbox && !library.assets.isEmpty
            )
            .animation(
                CharkleMotion.enterExit(isTrash && !library.assets.isEmpty, reduced: reduceMotion),
                value: isTrash && !library.assets.isEmpty
            )
            .animation(
                CharkleMotion.enterExit(activeFolderID != nil, reduced: reduceMotion),
                value: activeFolderID
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
        .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: library.selectedAssetIDs.count >= 2)
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            let orderedFolders = library.flattenedFolderHierarchy.map(\.folder)
            guard isInbox, press.modifiers.isEmpty,
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

    // MARK: - Floating Liquid Glass Top Bar

    private var floatingTopBar: some View {
        CharkleGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                // Search capsule
                HStack(spacing: 7) {
                    CharkleIcon("search", style: .duotone, size: 17, color: library.semanticSearchEnabled ? Color.accentColor : .secondary, isActive: library.semanticSearchEnabled)
                    TextField(
                        library.semanticSearchEnabled ? "自然语言语义搜图，回车检索…" : "搜索素材、标签、OCR 文字或拼音…",
                        text: $searchDraft
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .frame(minWidth: 68, idealWidth: 168, maxWidth: 260)
                    .onSubmit {
                        let q = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !q.isEmpty else { return }
                        if library.semanticSearchEnabled {
                            triggerSemanticSearch()
                        }
                    }

                    if !searchDraft.isEmpty {
                        Button {
                            searchDraft = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
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
                    } label: {
                        HStack(spacing: 3) {
                            if library.isRunningSemanticSearch {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Text("语义")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(library.semanticSearchEnabled ? Color.white : Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            library.semanticSearchEnabled ? Color.accentColor : Color.accentColor.opacity(0.12),
                            in: Capsule(style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("混合视觉语义搜图（结合 TypeSafe Jev 视觉评分 + 语义向量 + 全文）")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))

                // Visual Filter Toggle (⇧⌘S)
                Button {
                    let willOpen = !coordinator.isVisualFilterBarPresented
                    withAnimation(
                        CharkleMotion.enterExit(
                            willOpen,
                            enter: CharkleMotion.popoverEnter,
                            exit: CharkleMotion.popoverExit,
                            reduced: reduceMotion
                        )
                    ) {
                        coordinator.isVisualFilterBarPresented = willOpen
                    }
                } label: {
                    HStack(spacing: 5) {
                        CharkleIcon("filter", style: .duotone, size: 17, color: (coordinator.isVisualFilterBarPresented || library.filter.hasActiveVisualFilters) ? Color.accentColor : .primary, isActive: coordinator.isVisualFilterBarPresented || library.filter.hasActiveVisualFilters)
                        Text("筛选")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if library.filter.hasActiveVisualFilters {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .help("展开视觉与色彩筛选条 (⇧⌘S)")

                // Sort Picker Pill
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
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11))
                        Text(library.filter.sortBy.localizedLabel)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // 3-Mode Gallery View Switcher (Vertical Masonry / Horizontal Justified / Finder Filmstrip Gallery)
                HStack(spacing: 2) {
                    layoutModeButton(mode: .verticalMasonry, icon: "masonry-vertical", helpText: "纵向瀑布流")
                    layoutModeButton(mode: .horizontalJustified, icon: "masonry-horizontal", helpText: "横向等高瀑布流（竖图自动对齐）")
                    layoutModeButton(mode: .galleryFilmstrip, icon: "quicklook", helpText: "画廊视图（底部胶片挑图）")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3.5)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))

                // Column / Row Density Slider Pill (synced with trackpad pinch & ⌘+scroll)
                if coordinator.galleryLayoutMode != .galleryFilmstrip {
                    HStack(spacing: 6) {
                        Button {
                            coordinator.targetColumnWidth = max(130, coordinator.targetColumnWidth - 36)
                        } label: {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("缩小卡片、显示更多列（也支持双指捏合或 ⌘+滚轮）")

                        Slider(value: Binding(
                            get: { coordinator.targetColumnWidth },
                            set: { coordinator.targetColumnWidth = $0 }
                        ), in: 130...420)
                        .frame(width: 64)

                        Button {
                            coordinator.targetColumnWidth = min(420, coordinator.targetColumnWidth + 36)
                        } label: {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("放大卡片、更清晰浏览细节（也支持双指捏合或 ⌘+滚轮）")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
                    .help("支持触控板双指捏合缩放或按住 ⌘+滚轮缩放")
                }

                Spacer(minLength: 4)

                // Rapid Moodboard Generator CTA Pill
                Button {
                    coordinator.presentMoodboardGenerator(
                        entry: library.selectedAssetIDs.count >= 2 ? .selection : .prompt
                    )
                } label: {
                    HStack(spacing: 5) {
                        CharkleIcon("sparkle-board", style: .duotone, size: 17, color: Color.accentColor, isActive: true)
                        Text("快速生成情绪板")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(CharkleTactileButtonStyle())

                // Isolated Sync Status Pill so 20Hz live sync progress updates never re-render MainWindowView or VirtualizedMasonryView
                FloatingSyncStatusPill(
                    syncAndAI: syncAndAI,
                    onOpenSettings: {
                        let targetTab: CharkleSettingsTab = syncAndAI.syncConfig.mode == .localOnly ? .library : .sync
                        withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                            coordinator.openSettings(tab: targetTab)
                        }
                    },
                    onTriggerManualSync: triggerManualCloudSync
                )

                // Inspector Toggle
                Button {
                    coordinator.isInspectorVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(coordinator.isInspectorVisible ? Color.accentColor : .secondary)
                        .frame(width: 30, height: 30)
                        .charkleLiquidGlass(.regular, in: Circle(), interactive: true)
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .help("显示 / 隐藏右侧检查器")
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    // MARK: - Expandable Floating Liquid Glass Visual Filter Bar

    private var floatingVisualFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: All 7 MediaKind Chips + Clear Filter
            HStack(spacing: 6) {
                Text("媒体")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(MediaKind.allCases, id: \.self) { kind in
                            let active = library.filter.kinds.contains(kind)
                            Button {
                                if active { library.filter.kinds.remove(kind) }
                                else { library.filter.kinds.insert(kind) }
                                Task { await library.refreshAssets() }
                            } label: {
                                Text(kind.localizedLabel)
                                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                                    .foregroundStyle(active ? .white : .primary.opacity(0.84))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        active ? Color.accentColor : Color.primary.opacity(0.06),
                                        in: Capsule(style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 4)

                // Aspect Shape Pills
                HStack(spacing: 4) {
                    ForEach(AspectShape.allCases, id: \.self) { shape in
                        let active = library.filter.shape == shape
                        Button {
                            library.filter.shape = active ? nil : shape
                            Task { await library.refreshAssets() }
                        } label: {
                            Text(shape.localizedLabel)
                                .font(.system(size: 11, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? .white : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    active ? Color.accentColor : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if library.filter.hasActiveVisualFilters {
                    Button("清除") {
                        library.filter.clearVisualFilters()
                        Task { await library.refreshAssets() }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.plain)
                }
            }

            // Row 2: Friendly Color Filter + Tolerance Range + Rating + Kept Locally
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Text("色彩")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)

                    ForEach(Self.filterColorPresets, id: \.self) { hex in
                        let selected = library.filter.selectedColorHex?.uppercased() == hex
                        Button {
                            library.filter.selectedColorHex = selected ? nil : hex
                            Task { await library.refreshAssets() }
                        } label: {
                            Circle()
                                .fill(Color(charkleHex: hex))
                                .frame(width: 17, height: 17)
                                .overlay(
                                    Circle().strokeBorder(
                                        selected ? Color.accentColor : Color.primary.opacity(0.18),
                                        lineWidth: selected ? 2.5 : 0.75
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .help("按主色调筛选 \(hex)")
                    }

                    // Custom color picker (natural NSColorWell size via fixedSize so it never overlaps adjacent swatches)
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: {
                                Color(charkleHex: library.filter.selectedColorHex ?? "#3D5A80")
                            },
                            set: { newColor in
                                if let hex = Self.hexString(from: newColor) {
                                    library.filter.selectedColorHex = hex
                                    Task { await library.refreshAssets() }
                                }
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 4)
                    .help("自定义颜色或吸管取色")

                    if library.filter.selectedColorHex != nil {
                        HStack(spacing: 5) {
                            Text("精确")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { library.filter.colorTolerance },
                                set: { newVal in
                                    library.filter.colorTolerance = newVal
                                    Task { await library.refreshAssets() }
                                }
                            ), in: 10...55)
                            .frame(width: 74)
                            .help("调节颜色匹配范围：越靠左越接近所选颜色，越靠右包含更多相近色调")
                            Text("宽松")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(colorToleranceLabel(library.filter.colorTolerance))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.11), in: Capsule(style: .continuous))
                            Button {
                                library.filter.selectedColorHex = nil
                                Task { await library.refreshAssets() }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("清除颜色筛选")
                        }
                        .padding(.leading, 4)
                    }
                }

                Divider().frame(height: 16)

                // Minimum Rating Filter
                HStack(spacing: 3) {
                    Text("评分")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            library.filter.minRating = (library.filter.minRating == star) ? 0 : star
                            Task { await library.refreshAssets() }
                        } label: {
                            Image(systemName: star <= library.filter.minRating ? "star.fill" : "star")
                                .font(.system(size: 11))
                                .foregroundStyle(star <= library.filter.minRating ? Color(charkleHex: "#E5B243") : .secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider().frame(height: 16)

                // Kept Locally (iCloud-style) Filter Toggle
                Button {
                    library.filter.onlyPinnedOffline.toggle()
                    Task { await library.refreshAssets() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: library.filter.onlyPinnedOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 10.5))
                        Text("已保留在本地")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(library.filter.onlyPinnedOffline ? Color.accentColor : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        library.filter.onlyPinnedOffline ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
                        in: Capsule(style: .continuous)
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
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
                .foregroundStyle(Color.accentColor)
            Text(report.summary)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("返回普通检索") {
                library.semanticSearchEnabled = false
                Task { await library.clearSemanticSearch() }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("收件箱智能分拣预览 (Choice + Companion Noul)")
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
                                        .foregroundStyle(!hasTarget ? Color.secondary.opacity(0.45) : (isChecked ? Color.accentColor : Color.secondary))
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
                                    .foregroundStyle(rec.confidence >= 0.65 ? Color.accentColor : Color.primary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        (rec.confidence >= 0.65 ? Color.accentColor : Color.primary).opacity(0.10),
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
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("取消") {
                    showInboxBatchTriageSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("归档已勾选 (\(selectedRecs.count) 项)") {
                    let batch = selectedRecs
                    showInboxBatchTriageSheet = false
                    Task {
                        let moved = await library.applyInboxTriageRecommendations(batch)
                        coordinator.showToast("智能分拣完成：已归档 \(moved) 项素材", icon: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
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

        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                CharkleIcon("inbox", style: .duotone, size: 14, color: Color.accentColor)
                Text("待整理 \(library.inboxCount) 项")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }

            Divider().frame(height: 16)

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
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .help(suggestion.reason)
            }

            // Phase 2: Batch Inbox Smart Triage (TypeSafe Choice + Companion Noul)
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
                        Text(library.isRunningInboxTriage ? "分拣中…" : "智能分拣")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.10), in: Capsule(style: .continuous))
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .disabled(library.isRunningInboxTriage)
                .help("使用 TypeSafe Jev (Choice + 伴随 Noul) 批量识别收件箱素材并推荐归档目录")
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
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                    CharkleIcon("sparkle-board", style: .duotone, size: 12.5, color: Color.accentColor)
                    Text("一键收入情绪板")
                        .font(.system(size: 11.5, weight: .semibold))
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
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                pendingPermanentDeleteIDs = allIDs
            } label: {
                Label("清空废纸篓…", systemImage: "trash.slash")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.10), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Folder Breadcrumb + Subfolders Strip + Click-Outside Popover Creator

    private func folderSubfoldersBar(folderID: UUID) -> some View {
        let crumbs = library.folderBreadcrumbs(for: folderID)
        let children = library.childFolders(of: folderID)

        return HStack(spacing: 10) {
            // Breadcrumb path
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
                }
            }

            if !children.isEmpty {
                Divider().frame(height: 15)
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
                        .font(.system(size: 11))
                    Text("新建子文件夹")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.11), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCreateSubfolderPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("新建子文件夹")
                        .font(.system(size: 12.5, weight: .semibold))
                    HStack(spacing: 6) {
                        TextField("子文件夹名称", text: $subfolderNameDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 190)
                            .focused($isSubfolderFieldFocused)
                            .onSubmit { commitNewSubfolder(parentID: folderID) }
                        Button("创建") {
                            commitNewSubfolder(parentID: folderID)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private func colorToleranceLabel(_ tolerance: Double) -> String {
        if tolerance <= 18 { return "精确" }
        if tolerance <= 34 { return "适中" }
        return "宽松"
    }

    private static func hexString(from color: Color) -> String? {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    private var inboxZeroCelebrationView: some View {
        InboxZeroCelebrationView(
            onBrowseAll: { navigate(to: .allItems) },
            onGenerateBoard: { coordinator.presentMoodboardGenerator(entry: .prompt) }
        )
    }

    private var emptyLibraryView: some View {
        let isTrash = coordinator.selectedDestination == .trash
        let isFiltered = library.filter.hasActiveVisualFilters || !library.filter.searchQuery.isEmpty
        return VStack(spacing: 14) {
            if isTrash && !isFiltered {
                Image(systemName: "trash")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("废纸篓是空的")
                    .font(.system(size: 17, weight: .semibold))
                Text("移至废纸篓的素材会暂存在这里，你可以随时放回原处或彻底删除。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                CharkleIcon("library", style: .layered, size: 60, color: .secondary.opacity(0.6))
                Text(isFiltered ? "没有符合筛选条件的素材" : "这里还没有素材")
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
                            Task { await library.refreshAssets() }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("采集剪贴板 (⌥⇧V)") { onCollectClipboard() }
                        .buttonStyle(.borderedProminent)
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

        return CharkleGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                Text("已选 \(ids.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .padding(.leading, 4)

                Rectangle().fill(CharkleTheme.hairline(for: colorScheme)).frame(width: 1, height: 16)

                if isTrashSelection {
                    Button {
                        Task {
                            await library.restoreAssets(ids)
                            coordinator.showToast("已将 \(ids.count) 项放回原处", icon: "arrow.uturn.backward")
                        }
                    } label: {
                        Label("放回原处", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())

                    Button(role: .destructive) {
                        pendingPermanentDeleteIDs = ids
                    } label: {
                        Label("彻底删除", systemImage: "trash.slash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.10), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
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
                            CharkleIcon("sparkle-board", style: .duotone, size: 13.5, color: .white)
                            Text("生成情绪板")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())

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
                        Label("移动", systemImage: "folder")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        showBatchTagPopover.toggle()
                    } label: {
                        Label("加标签", systemImage: "tag")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showBatchTagPopover) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("为 \(ids.count) 项素材添加标签")
                                .font(.system(size: 12, weight: .semibold))
                            TextField("输入标签回车…", text: $quickBatchTagDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onSubmit {
                                    let val = quickBatchTagDraft
                                    quickBatchTagDraft = ""
                                    showBatchTagPopover = false
                                    Task { await library.addTags([val], to: ids) }
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
                                Text("打标中 \(library.enrichCompletedCount)/\(max(1, library.enrichTotalCount))")
                                    .monospacedDigit()
                            } else {
                                Image(systemName: "sparkles")
                                Text("AI 打标")
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
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
                        Label("评分", systemImage: "star")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

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
                        Image(systemName: allKeptLocally ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(allKeptLocally ? Color.accentColor : Color.primary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(allKeptLocally ? "取消全部保留在本地" : "全部始终保留在本地")

                    Button(role: .destructive) {
                        Task {
                            await library.trashAssets(ids)
                            coordinator.showToast("已移至废纸篓", icon: "trash")
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
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
                    .buttonStyle(.bordered)

                    Button {
                        coordinator.presentMoodboardGenerator(entry: .prompt)
                    } label: {
                        HStack(spacing: 5) {
                            CharkleIcon("sparkle-board", style: .duotone, size: 14, color: .white)
                            Text("10 秒快速生成")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)], spacing: 16) {
                    // Quick Generate Card
                    Button {
                        coordinator.presentMoodboardGenerator(entry: .prompt)
                    } label: {
                        VStack(spacing: 10) {
                            CharkleIcon("sparkle-board", style: .layered, size: 42, color: Color.accentColor)
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
                                .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1.25, dash: [6, 5]))
                        )
                    }
                    .buttonStyle(CharkleTactileButtonStyle())

                    ForEach(moodboards.boards) { board in
                        moodboardSummaryCard(board)
                    }
                }
            }
            .padding(24)
            .charkleCleanScrollbars(hidden: false)
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
                            CharkleIcon("moodboard", style: .layered, size: 32, color: .secondary.opacity(0.5))
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
                        Text("活跃板")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12), in: Capsule(style: .continuous))
                    }
                    if board.pinnedOffline {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
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
                        if coordinator.quickLookAssetID != nil {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.gestureSpring, reduced: reduceMotion)) {
                                coordinator.closeQuickLook()
                            }
                        } else {
                            let playlist = board.referencedAssetIDs
                            coordinator.openQuickLook(assetID: asset.id, playlist: playlist.isEmpty ? [asset.id] : playlist)
                        }
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
                        Task {
                            if let internalPaste = library.internalPasteboardAssets() {
                                let resolved = internalPaste.ids.compactMap { library.allAssetsByID[$0] }
                                guard !resolved.isEmpty else { return }
                                await moodboards.appendAssets(resolved, at: dropPoint)
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
                                await moodboards.appendAssets(created, at: dropPoint)
                                coordinator.showToast("已粘贴导入并加入情绪板 (\(created.count) 项)", icon: "doc.on.clipboard")
                            }
                        }
                    },
                    onDropExternalInputs: { inputs, dropPoint in
                        // Single Source of Truth: new files go into /Charkle/Inbox/ (folderID = nil) and place at dropPoint
                        Task {
                            let created = await library.ingest(inputs, targetFolderID: nil, targetBoardID: nil)
                            await moodboards.appendAssets(created, at: dropPoint)
                            coordinator.showToast("已入收件箱并放置在画布 (\(created.count) 项)", icon: "arrow.down.circle.fill")
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
                            .font(.system(size: 12, weight: .medium))
                        Text(coordinator.isInspectorVisible ? "收起候选栏" : "候选替换池")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .padding(.top, 14)
                .padding(.trailing, 18)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在加载情绪板…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CharkleTheme.galleryGround(for: colorScheme))
        }
    }

    // MARK: - Actions & Navigation

    private func navigate(to destination: SidebarDestination) {
        coordinator.selectedDestination = destination
        switch destination {
        case .moodboard(let id):
            coordinator.activeMoodboardID = id
            Task { await moodboards.openBoard(id: id) }
        case .moodboardsHome:
            Task { await moodboards.refreshBoards() }
        default:
            Task { await library.applyDestination(destination) }
        }
    }

    private func layoutModeButton(mode: GalleryLayoutMode, icon: String, helpText: String) -> some View {
        let active = coordinator.galleryLayoutMode == mode
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                coordinator.galleryLayoutMode = mode
            }
        } label: {
            CharkleIcon(icon, style: .duotone, size: 16, isActive: active)
                .frame(width: 28, height: 24)
                .background(
                    active ? Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10) : Color.clear,
                    in: Capsule(style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func openQuickLook(_ asset: AssetRecord) {
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
                navigate(to: .allItems)
                library.selectedAssetIDs = [id]
                if let asset = library.allAssetsByID[id] {
                    openQuickLook(asset)
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

    private func toastTint(_ tone: ToastTone) -> Color {
        switch tone {
        case .neutral: Color.accentColor
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Isolated top-bar sync pill & progress popover so frequent live sync progress broadcasts
/// update only this compact control rather than triggering full Gallery / MainWindowView diffs.
private struct FloatingSyncStatusPill: View {
    let syncAndAI: SyncAndAIStore
    let onOpenSettings: () -> Void
    let onTriggerManualSync: () -> Void

    @State private var showSyncPopover: Bool = false

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
        .buttonStyle(CharkleTactileButtonStyle())
        .popover(isPresented: $showSyncPopover, arrowEdge: .bottom) {
            cloudSyncProgressPopover
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
        .help(syncAndAI.syncConfig.mode == .localOnly ? "当前为本地保存，点击打开存储设置" : "点击查看云端同步进度与状态")
    }

    private var syncDotColor: Color {
        switch syncAndAI.syncStatus.phase {
        case .error: return .red
        case .scanning, .uploading, .downloading, .merging: return .orange
        case .idle:
            if syncAndAI.syncConfig.mode == .localOnly { return .secondary }
            return syncAndAI.syncStatus.pendingOpCount > 0 ? .orange : .green
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
                                .foregroundStyle(Color.accentColor)
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
                            .tint(Color.accentColor)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
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
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .foregroundStyle(status.pendingOpCount > 0 ? .orange : .secondary)
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
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    onTriggerManualSync()
                } label: {
                    Text(isSyncing ? "同步中…" : "立即同步")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSyncing)

                Button("存储设置…") {
                    showSyncPopover = false
                    onOpenSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            CharkleIcon("inbox", style: .layered, size: 64, color: Color(charkleHex: "#6B8E76"))
                .scaleEffect(appeared ? 1.0 : (reduceMotion ? 1.0 : 0.92))
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
                        .buttonStyle(.bordered)
                    Button("10 秒生成情绪板", action: onGenerateBoard)
                        .buttonStyle(.borderedProminent)
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

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
    @Environment(\.openSettings) private var openSettings

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotch: () -> Void
    public let onCaptureArea: () -> Void
    public let onCollectClipboard: () -> Void

    @Namespace private var heroNamespace

    @State private var searchDraft: String = ""
    @State private var isSidebarVisible: Bool = true
    @State private var quickBatchTagDraft: String = ""
    @State private var showBatchTagPopover: Bool = false
    @State private var pendingPermanentDeleteIDs: [UUID] = []
    @State private var showCreateSubfolderPopover: Bool = false
    @State private var subfolderNameDraft: String = ""
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
        onCollectClipboard: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.syncAndAI = syncAndAI
        self.onToggleNotch = onToggleNotch
        self.onCaptureArea = onCaptureArea
        self.onCollectClipboard = onCollectClipboard
    }

    public var body: some View {
        ZStack {
            // Native 3-pane studio layout (avoids macOS 26/27 NavigationSplitView + hiddenTitleBar
            // ScrollView safe-area hit-test vertical offset bug, ensuring 0px-accurate sidebar clicks).
            // Sidebar and Inspector keep deterministic fixed internal widths inside animated width slots
            // so rapid collapse/expand cycles never get stuck half-open or overflow past window bounds.
            HStack(spacing: 0) {
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
                    .frame(width: 232)
                    .background {
                        CharkleSidebarMaterialBackground()
                            .ignoresSafeArea(.container, edges: .top)
                    }

                    Rectangle()
                        .fill(CharkleTheme.hairline(for: colorScheme))
                        .frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .frame(width: 233)
                .frame(maxHeight: .infinity)
                .opacity(isSidebarVisible ? 1 : 0)
                .allowsHitTesting(isSidebarVisible)
                .disabled(!isSidebarVisible)
                .accessibilityHidden(!isSidebarVisible)
                .frame(width: isSidebarVisible ? 233 : 0, alignment: .trailing)
                .mask {
                    Rectangle()
                        .ignoresSafeArea(.container, edges: .top)
                }
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
                    }
                )
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .opacity(coordinator.isInspectorVisible ? 1 : 0)
                .allowsHitTesting(coordinator.isInspectorVisible)
                .disabled(!coordinator.isInspectorVisible)
                .accessibilityHidden(!coordinator.isInspectorVisible)
                .frame(width: coordinator.isInspectorVisible ? 300 : 0, alignment: .leading)
                .mask {
                    Rectangle()
                        .ignoresSafeArea(.container, edges: .top)
                }
                .layoutPriority(1)
            }
            .animation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion), value: isSidebarVisible)
            .animation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion), value: coordinator.isInspectorVisible)

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
                        withAnimation(CharkleMotion.accessible(CharkleMotion.gestureSpring, reduced: reduceMotion)) {
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
            await library.bootstrap()
            await moodboards.refreshBoards()
            await syncAndAI.loadAll()
            if coordinator.activeMoodboardID == nil {
                coordinator.activeMoodboardID = moodboards.boards.first?.id
            }
        }
        .onChange(of: searchDraft) { _, newValue in
            library.filter.searchQuery = newValue
            Task { await library.refreshAssets() }
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
            } else {
                VirtualizedMasonryView(
                    assets: library.assets,
                    folders: library.folders,
                    loader: library.thumbnailLoader,
                    selectedAssetIDs: Binding(
                        get: { library.selectedAssetIDs },
                        set: { library.selectedAssetIDs = $0 }
                    ),
                    cutAssetIDs: library.cutAssetIDs,
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
                            if !library.cutAssetIDs.isEmpty {
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
                        onResolveDragFileURL: { _ in nil }
                    )
                )
            }

            // Floating Liquid Glass Top Control Stack
            VStack(spacing: 8) {
                floatingTopBar

                if coordinator.isVisualFilterBarPresented {
                    floatingVisualFilterBar
                        .popoverOriginScale(
                            isPresented: coordinator.isVisualFilterBarPresented,
                            anchor: .top,
                            reducedMotion: reduceMotion
                        )
                }

                if isInbox && !library.assets.isEmpty {
                    inboxTriageBar
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }

                if isTrash && !library.assets.isEmpty {
                    trashActionBar
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }

                if let activeFolderID {
                    folderSubfoldersBar(folderID: activeFolderID)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

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
            guard isInbox, press.modifiers.isEmpty,
                  let digit = Int(press.characters),
                  digit >= 1, digit <= library.folders.count else { return .ignored }
            let targetFolder = library.folders[digit - 1]
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
                coordinator.showToast("已快捷键归档至「\(targetFolder.name)」", icon: "folder.fill")
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
                    CharkleIcon("search", style: .duotone, size: 14, color: .secondary)
                    TextField("搜索素材、标签、OCR 文字或拼音…", text: $searchDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .frame(minWidth: 68, idealWidth: 160, maxWidth: 260)

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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))

                // Visual Filter Toggle (⇧⌘S)
                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.popoverEnter, reduced: reduceMotion)) {
                        coordinator.isVisualFilterBarPresented.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        CharkleIcon("filter", style: .duotone, size: 14, color: (coordinator.isVisualFilterBarPresented || library.filter.hasActiveVisualFilters) ? Color.accentColor : .primary)
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

                // Column Density Slider Pill
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { coordinator.targetColumnWidth },
                        set: { coordinator.targetColumnWidth = $0 }
                    ), in: 168...316)
                    .frame(width: 58)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .charkleLiquidGlass(.regular, in: Capsule(style: .continuous))
                .help("调整画廊瀑布流列宽密度")

                Spacer(minLength: 4)

                // Rapid Moodboard Generator CTA Pill
                Button {
                    coordinator.presentMoodboardGenerator(
                        entry: library.selectedAssetIDs.count >= 2 ? .selection : .prompt
                    )
                } label: {
                    HStack(spacing: 5) {
                        CharkleIcon("sparkle-board", style: .duotone, size: 14, color: Color.accentColor)
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

                // Sync Status Pill
                Button {
                    Task {
                        if let report = await syncAndAI.syncNow() {
                            await library.refreshAll()
                            await moodboards.refreshBoards()
                            coordinator.showToast("同步完成 (+\(report.discoveredRemoteAssets) 新发现)", icon: "checkmark.icloud.fill")
                        } else if let err = syncAndAI.errorMessage {
                            coordinator.showToast(err, icon: "exclamationmark.icloud", tone: .warning)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if syncAndAI.isBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(syncDotColor)
                                .frame(width: 7, height: 7)
                        }
                        Text(syncPillLabel)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .contextMenu {
                    Button("打开 Google Drive 与 gdirect 设置…") { openSettings() }
                }
                .help("点击立即同步 Google Drive")

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

            // Quick 1–9 Folder Archive Chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(library.folders.prefix(9).enumerated()), id: \.element.id) { idx, folder in
                        Button {
                            guard !targetIDs.isEmpty else { return }
                            Task {
                                await library.moveAssets(targetIDs, toFolderID: folder.id)
                                coordinator.showToast("已归档至「\(folder.name)」", icon: "folder.fill")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                Text(folder.name)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
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
                                CharkleIcon("folder", style: .duotone, size: 13, color: Color.accentColor)
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
                            Button {
                                navigate(to: .folder(child.id))
                            } label: {
                                HStack(spacing: 5) {
                                    CharkleIcon("folder", style: .duotone, size: 12, color: .secondary)
                                    Text(child.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                    if child.assetCount > 0 {
                                        Text("\(child.assetCount)")
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
        VStack(spacing: 14) {
            CharkleIcon("inbox", style: .layered, size: 64, color: Color(charkleHex: "#6B8E76"))
            Text("收件箱已清空")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.2)
            Text("所有灵感都已妥善归档或进入情绪板。随时拖动文件到 MacBook 刘海或按 ⌥⇧A 截图采集。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("浏览全部素材") { navigate(to: .allItems) }
                    .buttonStyle(.bordered)
                Button("10 秒生成情绪板") { coordinator.presentMoodboardGenerator(entry: .prompt) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CharkleTheme.galleryGround(for: colorScheme))
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
                        Button("收件箱") { Task { await library.moveAssets(ids, toFolderID: nil) } }
                        Divider()
                        ForEach(library.folders) { folder in
                            Button(library.folderDisplayPath(for: folder.id)) {
                                Task {
                                    await library.moveAssets(ids, toFolderID: folder.id)
                                    coordinator.showToast("已移动到「\(folder.name)」", icon: "folder")
                                }
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
                        Text("单源引用素材库 · 随时无缝切换自动排版与自由白板")
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
                    Text(board.mode.isAutoEditorial ? "自动排版" : "自由画布")
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

    private func openQuickLook(_ asset: AssetRecord) {
        let playlist = library.assets.map(\.id)
        withAnimation(CharkleMotion.accessible(CharkleMotion.gestureSpring, reduced: reduceMotion)) {
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

    private var syncDotColor: Color {
        switch syncAndAI.syncStatus.phase {
        case .error: .red
        case .scanning, .uploading, .downloading, .merging: .orange
        case .idle:
            syncAndAI.syncConfig.mode == .localOnly ? .secondary : .green
        }
    }

    private var syncPillLabel: String {
        switch syncAndAI.syncStatus.phase {
        case .scanning: "扫描中…"
        case .uploading(let done, let total): "上传 \(done)/\(total)"
        case .downloading(let done, let total): "下载 \(done)/\(total)"
        case .merging: "合并中…"
        case .error: "同步异常"
        case .idle:
            switch syncAndAI.syncConfig.mode {
            case .localOnly: "本地保存"
            case .directAPIWithGDirect: "Google Drive"
            case .webDAV: "WebDAV"
            case .gdirectMount: "Drive 挂载"
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

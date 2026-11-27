import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Refined translucent macOS Sidebar supporting:
/// - Smooth collapse into an icon-only rail (`76pt` <-> `232pt`) with zero-flicker fixed inner frames
/// - Crisp SF Symbols dual-state navigation icons (`.symbolVariant(.fill)`) + custom colored folder vectors
/// - Smart Folders with live rule matching
/// - Hierarchical Folders with in-app drag-to-reorder / drag-to-nest AND external Finder folder drop
/// - Capped Tags section (Top 10 most-used + up to 5 recent frequent + searchable All Tags popover)
public struct SidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let expandedWidth: CGFloat
    public let isDraggingDivider: Bool
    public let onImportMaterialPackage: (() -> Void)?
    public let onExportFolderToPureRef: ((FolderRecord, Bool) -> Void)?
    public let onOpenSmartDeduplication: ((UUID?) -> Void)?
    public let onSelectDestination: (SidebarDestination) -> Void
    public let onDropAssetsOntoFolder: ([UUID], UUID?) -> Void
    public let onDropExternalOntoFolder: ([CaptureInput], UUID?) -> Void
    public let onDropAssetsOntoBoard: ([UUID], UUID) -> Void
    public let onDropExternalOntoBoard: ([CaptureInput], UUID) -> Void

    @Namespace private var expandedSelectionNamespace
    @Namespace private var collapsedSelectionNamespace

    private enum FolderCreationTarget: Equatable {
        case root
        case subfolder(UUID)

        var parentID: UUID? {
            switch self {
            case .root: nil
            case .subfolder(let id): id
            }
        }
    }

    private struct FolderSlotKey: Hashable {
        let parentID: UUID?
        let index: Int
    }

    private struct FolderTreeNode: Identifiable {
        let folder: FolderRecord
        let depth: Int
        let siblingIndex: Int
        let siblingCount: Int
        let hasChildren: Bool
        let isExpanded: Bool
        var id: UUID { folder.id }
    }

    @State private var creationTarget: FolderCreationTarget?
    @State private var lastDismissedTarget: FolderCreationTarget?
    @State private var lastDismissedAt: Date = .distantPast
    @State private var newFolderName: String = ""
    @FocusState private var isNewFolderFieldFocused: Bool

    @State private var renamingFolderID: UUID?
    @State private var renameDraft: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var didSeedInitialExpansion: Bool = false
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var lastClickedFolderID: UUID?
    @State private var customizingFolderID: UUID?
    @State private var pendingDeleteWithContentsFolders: [FolderRecord] = []
    @State private var pendingDeleteBoard: MoodboardSummary?

    @State private var dropTargetedFolderID: UUID?
    @State private var dropTargetedFolderRoot: Bool = false
    @State private var dropTargetedSlot: FolderSlotKey?
    @State private var dropTargetedInbox: Bool = false
    @State private var dropTargetedBoardID: UUID?

    @State private var isTagsSectionExpanded: Bool = true
    @State private var isAllTagsPopoverPresented: Bool = false
    @State private var allTagsSearchQuery: String = ""
    @State private var allTagsSortByCount: Bool = true

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        expandedWidth: CGFloat = AppCoordinatorStore.defaultSidebarWidth,
        isDraggingDivider: Bool = false,
        onImportMaterialPackage: (() -> Void)? = nil,
        onExportFolderToPureRef: ((FolderRecord, Bool) -> Void)? = nil,
        onOpenSmartDeduplication: ((UUID?) -> Void)? = nil,
        onSelectDestination: @escaping (SidebarDestination) -> Void,
        onDropAssetsOntoFolder: @escaping ([UUID], UUID?) -> Void,
        onDropExternalOntoFolder: @escaping ([CaptureInput], UUID?) -> Void,
        onDropAssetsOntoBoard: @escaping ([UUID], UUID) -> Void,
        onDropExternalOntoBoard: @escaping ([CaptureInput], UUID) -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.expandedWidth = expandedWidth
        self.isDraggingDivider = isDraggingDivider
        self.onImportMaterialPackage = onImportMaterialPackage
        self.onExportFolderToPureRef = onExportFolderToPureRef
        self.onOpenSmartDeduplication = onOpenSmartDeduplication
        self.onSelectDestination = onSelectDestination
        self.onDropAssetsOntoFolder = onDropAssetsOntoFolder
        self.onDropExternalOntoFolder = onDropExternalOntoFolder
        self.onDropAssetsOntoBoard = onDropAssetsOntoBoard
        self.onDropExternalOntoBoard = onDropExternalOntoBoard
    }

    private var visibleFolderTree: [FolderTreeNode] {
        var nodes: [FolderTreeNode] = []
        nodes.reserveCapacity(library.folders.count)
        var visited = Set<UUID>()
        visited.reserveCapacity(library.folders.count)

        func visit(parentID: UUID?, depth: Int) {
            let childrenList = library.childFolders(of: parentID)
            for (idx, folder) in childrenList.enumerated() where visited.insert(folder.id).inserted {
                let hasChildren = !library.childFolders(of: folder.id).isEmpty
                let isExpanded = expandedFolderIDs.contains(folder.id) || creationTarget == .subfolder(folder.id)
                nodes.append(
                    FolderTreeNode(
                        folder: folder,
                        depth: depth,
                        siblingIndex: idx,
                        siblingCount: childrenList.count,
                        hasChildren: hasChildren,
                        isExpanded: isExpanded
                    )
                )
                if hasChildren && isExpanded {
                    visit(parentID: folder.id, depth: depth + 1)
                }
            }
        }

        visit(parentID: nil, depth: 0)

        for folder in library.folders where !visited.contains(folder.id) && (folder.parentID == nil || library.folder(byID: folder.parentID!) == nil) {
            nodes.append(
                FolderTreeNode(
                    folder: folder,
                    depth: 0,
                    siblingIndex: nodes.count,
                    siblingCount: nodes.count + 1,
                    hasChildren: false,
                    isExpanded: false
                )
            )
        }
        return nodes
    }

    public var body: some View {
        Group {
            if coordinator.isSidebarCollapsed {
                collapsedRailBody
                    .frame(width: AppCoordinatorStore.collapsedSidebarWidth)
            } else {
                expandedSidebarBody
                    .frame(width: expandedWidth)
            }
        }
        .animation(
            isDraggingDivider ? nil : CharkleMotion.accessible(CharkleMotion.drawerEase, reduced: reduceMotion),
            value: coordinator.isSidebarCollapsed
        )
        .onAppear {
            seedInitialExpansionIfNeeded()
        }
        .onChange(of: library.folders) { _, _ in
            seedInitialExpansionIfNeeded()
        }
        .onChange(of: coordinator.selectedDestination) { _, newDest in
            if case .folder(let folderID) = newDest {
                expandAncestors(of: folderID)
            } else if !selectedFolderIDs.isEmpty {
                selectedFolderIDs.removeAll()
            }
        }
        .alert(
            pendingDeleteWithContentsFolders.count > 1
                ? "删除所选 \(pendingDeleteWithContentsFolders.count) 个文件夹及其中素材？"
                : "删除「\(pendingDeleteWithContentsFolders.first?.name ?? "")」及其中素材？",
            isPresented: Binding(
                get: { !pendingDeleteWithContentsFolders.isEmpty },
                set: { if !$0 { pendingDeleteWithContentsFolders = [] } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingDeleteWithContentsFolders = []
            }
            Button("连同素材一起删除", role: .destructive) {
                let targets = pendingDeleteWithContentsFolders
                pendingDeleteWithContentsFolders = []
                Task {
                    var totalTrashed = 0
                    for folder in targets {
                        totalTrashed += await library.deleteFolder(id: folder.id, trashContents: true)
                    }
                    selectedFolderIDs.subtract(targets.map(\.id))
                    if case .folder(let currentID) = coordinator.selectedDestination,
                       !library.folders.contains(where: { $0.id == currentID }) {
                        onSelectDestination(.allItems)
                    }
                    let msg = targets.count > 1
                        ? "已删除 \(targets.count) 个文件夹，\(totalTrashed) 项素材已移至废纸篓"
                        : (totalTrashed > 0
                            ? "已删除「\(targets.first?.name ?? "")」，\(totalTrashed) 项素材已移至废纸篓"
                            : "已删除文件夹「\(targets.first?.name ?? "")」")
                    coordinator.showToast(msg, icon: "trash")
                }
            }
        } message: {
            if !pendingDeleteWithContentsFolders.isEmpty {
                let count = pendingDeleteWithContentsFolders.reduce(0) { $0 + library.subtreeAssetCount(for: $1.id) }
                Text(count > 0
                    ? "将删除所选文件夹及其子文件夹，并将里面的 \(count) 项素材一并移至废纸篓（可在废纸篓中恢复或彻底删除）。"
                    : "将删除所选文件夹及其子文件夹。")
            }
        }
        .alert(
            "删除情绪板「\(pendingDeleteBoard?.title ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteBoard != nil },
                set: { if !$0 { pendingDeleteBoard = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingDeleteBoard = nil
            }
            Button("删除情绪板", role: .destructive) {
                guard let target = pendingDeleteBoard else { return }
                pendingDeleteBoard = nil
                Task {
                    await moodboards.deleteBoard(id: target.id)
                    if coordinator.selectedDestination == .moodboard(target.id) {
                        onSelectDestination(.moodboardsHome)
                    }
                    if coordinator.activeMoodboardID == target.id {
                        coordinator.activeMoodboardID = moodboards.boards.first?.id
                    }
                    coordinator.showToast("已删除情绪板「\(target.title)」", icon: "trash")
                }
            }
        } message: {
            Text("情绪板中的排版、便签、分组与连线将被永久删除，引用的原始素材仍安全保留在素材库中。")
        }
    }

    // MARK: - Collapsed Icon-Only Rail (76pt — clears macOS traffic lights symmetrically)

    private var collapsedRailBody: some View {
        VStack(spacing: 0) {
            // Draggable top clearance behind macOS traffic lights
            CharkleWindowDragArea()
                .frame(height: 36)

            // Pinned top controls cleanly beneath the traffic lights
            VStack(spacing: 6) {
                Button {
                    coordinator.isSidebarCollapsed = false
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                }
                .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 34))
                .help("展开侧边栏 (⌘\\)")

                Button {
                    coordinator.isJumpAnywherePresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .frame(width: 34, height: 32)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                }
                .buttonStyle(CharkleTactileButtonStyle())
                .help("快速跳转 (⌘J)")
            }
            .padding(.top, 2)
            .padding(.bottom, 8)

            railDivider

            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    railButton(destination: .allItems, symbolName: "square.grid.2x2", tooltip: "全部素材")
                    railButton(
                        destination: .inbox,
                        symbolName: "tray.and.arrow.down",
                        tooltip: "收件箱 (\(library.inboxCount))",
                        showDot: library.inboxCount > 0,
                        isDropHighlighted: dropTargetedInbox
                    )
                    .onDrop(of: [.plainText, .fileURL, .url, .image], isTargeted: $dropTargetedInbox) { providers in
                        handleDrop(providers: providers, folderID: nil, boardID: nil)
                    }
                    railButton(destination: .untagged, symbolName: "tag.slash", tooltip: "未打标签")
                    railButton(destination: .recent, symbolName: "clock", tooltip: "最近添加")
                    railButton(destination: .moodboardsHome, symbolName: "rectangle.3.group", tooltip: "所有情绪板")
                    railButton(destination: .pinterest, symbolName: "sparkles", tooltip: "Pinterest 无限空间")

                    if !library.smartFolders.isEmpty {
                        railDivider
                        ForEach(library.smartFolders.prefix(6)) { sf in
                            railButton(
                                destination: .smartFolder(sf.id),
                                symbolName: "folder.badge.gearshape",
                                tooltip: "智能文件夹：\(sf.name) (\(library.matchingCount(for: sf)))"
                            )
                        }
                    }

                    let topFolders = library.childFolders(of: nil)
                    if !topFolders.isEmpty {
                        railDivider
                        ForEach(topFolders.prefix(8)) { folder in
                            let isSelected = coordinator.selectedDestination == .folder(folder.id)
                            let shape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                    onSelectDestination(.folder(folder.id))
                                }
                            } label: {
                                CharkleFolderIcon(
                                    colorHex: folder.colorHex,
                                    customSymbol: folder.customSymbol,
                                    size: 19,
                                    isActive: isSelected
                                )
                                .frame(width: 38, height: 34)
                                .background {
                                    if isSelected {
                                        shape
                                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))
                                            .matchedGeometryEffect(id: "sidebar-collapsed-selection-pill", in: collapsedSelectionNamespace)
                                    } else if dropTargetedFolderID == folder.id {
                                        shape
                                            .fill(activeAccent.opacity(0.18))
                                            .overlay(shape.strokeBorder(activeAccent, lineWidth: 1.5))
                                    }
                                }
                                .contentShape(shape)
                            }
                            .buttonStyle(.plain)
                            .help("\(folder.name) (\(library.subtreeAssetCount(for: folder.id)))")
                            .onDrop(
                                of: [.plainText, .fileURL, .url, .image],
                                isTargeted: Binding(
                                    get: { dropTargetedFolderID == folder.id },
                                    set: { targeted in
                                        dropTargetedFolderID = targeted ? folder.id : (dropTargetedFolderID == folder.id ? nil : dropTargetedFolderID)
                                    }
                                )
                            ) { providers in
                                handleDrop(providers: providers, folderID: folder.id, boardID: nil)
                            }
                        }
                    }

                    railDivider

                    if !library.tagCounts.isEmpty {
                        Button {
                            isAllTagsPopoverPresented = true
                        } label: {
                            Image(systemName: "tag")
                                .font(.system(size: 15, weight: .medium))
                                .symbolVariant(isAllTagsPopoverPresented ? .fill : .none)
                                .foregroundStyle(isAllTagsPopoverPresented ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                                .frame(width: 38, height: 34)
                                .background(
                                    isAllTagsPopoverPresented
                                        ? Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("查看全部标签 (\(library.tagCounts.count))")
                        .popover(isPresented: $isAllTagsPopoverPresented, arrowEdge: .trailing) {
                            allTagsPopoverContent
                                .environment(\.charkleAccentSource, accentSource)
                                .tint(activeAccent)
                        }
                    }

                    railButton(destination: .trash, symbolName: "trash", tooltip: "废纸篓")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .charkleCleanScrollbars(hidden: true)
            }
            .scrollIndicators(.hidden)
            .clipped()

            CharkleHairlineDivider()

            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                    coordinator.openSettings()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15.5, weight: .medium))
                    .symbolVariant(coordinator.isSettingsPresented ? .fill : .none)
                    .foregroundStyle(coordinator.isSettingsPresented ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                    .frame(width: 38, height: 34)
                    .background(
                        coordinator.isSettingsPresented
                            ? Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("设置 (⌘,)")
            .padding(.vertical, 8)
        }
    }

    private var railDivider: some View {
        Rectangle()
            .fill(CharkleTheme.hairline(for: colorScheme))
            .frame(width: 24, height: CharkleTheme.hairlineWidth)
            .padding(.vertical, 2)
    }

    private func railButton(
        destination: SidebarDestination,
        symbolName: String,
        tooltip: String,
        showDot: Bool = false,
        isDropHighlighted: Bool = false
    ) -> some View {
        let isSelected = coordinator.selectedDestination == destination
        let shape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                onSelectDestination(destination)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbolName)
                    .font(.system(size: 15.5, weight: isSelected ? .semibold : .medium))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                    .frame(width: 38, height: 34)
                    .background {
                        if isSelected {
                            shape
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))
                                .matchedGeometryEffect(id: "sidebar-collapsed-selection-pill", in: collapsedSelectionNamespace)
                        } else if isDropHighlighted {
                            shape
                                .fill(activeAccent.opacity(0.18))
                                .overlay(shape.strokeBorder(activeAccent, lineWidth: 1.5))
                        }
                    }

                if showDot {
                    Circle()
                        .fill(activeAccent)
                        .frame(width: 7, height: 7)
                        .offset(x: -5, y: 5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Expanded Full Sidebar (232pt)

    private var expandedSidebarBody: some View {
        VStack(spacing: 0) {
            // Unified top window-chrome row: traffic lights float natively on the left;
            // Quick Jump & sidebar collapse align right alongside them on the same continuous surface.
            ZStack {
                CharkleWindowDragArea()

                HStack(spacing: 6) {
                    Spacer(minLength: 72)

                    Button {
                        coordinator.isJumpAnywherePresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10.5, weight: .medium))
                            Text("⌘J")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                    .help("快速跳转 (⌘J)")

                    Button {
                        coordinator.isSidebarCollapsed = true
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .icon, iconDimension: 26))
                    .help("收起为仅图标侧边栏 (⌘\\)")
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 36)

            // Calm brand identity seamlessly integrated on the same sidebar surface (no harsh boxed seam)
            HStack(spacing: 8) {
                CharkleBrandMark(size: 20)
                Text("Charkle")
                    .font(.system(size: 13.5, weight: .semibold))
                    .tracking(-0.2)
                Spacer()
            }
            .padding(.horizontal, 13)
            .padding(.top, 2)
            .padding(.bottom, 8)
            .background(CharkleWindowDragArea())

            sidebarSectionDivider

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                // Section 1: Library
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        sectionHeader("素材库")
                        Spacer()
                        if let onOpenSmartDeduplication {
                            Button {
                                onOpenSmartDeduplication(nil)
                            } label: {
                                Image(systemName: "square.on.square.dashed")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("全媒体智能去重（纯本地算法，保留最高质量 · ⌘⇧D）")
                        }
                    }
                    .padding(.trailing, 10)
                    sidebarRow(
                        destination: .allItems,
                        symbolName: "square.grid.2x2",
                        title: "全部素材",
                        badgeCount: library.activeAssetCount
                    )
                    sidebarRow(
                        destination: .inbox,
                        symbolName: "tray.and.arrow.down",
                        title: "收件箱",
                        badgeCount: library.inboxCount,
                        emphasizeBadge: library.inboxCount > 0,
                        isDropHighlighted: dropTargetedInbox
                    )
                    .onDrop(of: [.plainText, .fileURL, .url, .image], isTargeted: $dropTargetedInbox) { providers in
                        handleDrop(providers: providers, folderID: nil, boardID: nil)
                    }
                    .contextMenu {
                        if !library.cutAssetIDs.isEmpty {
                            Button {
                                Task {
                                    let count = await library.pasteCutAssets(toFolderID: nil)
                                    coordinator.showToast("已将 \(count) 项素材移至收件箱", icon: "tray.and.arrow.down")
                                }
                            } label: {
                                Label("粘贴移动至此（\(library.cutAssetIDs.count) 项）", systemImage: "doc.on.clipboard")
                            }
                        }
                    }
                    sidebarRow(
                        destination: .untagged,
                        symbolName: "tag.slash",
                        title: "未打标签",
                        badgeCount: library.untaggedAssetCount
                    )
                    sidebarRow(
                        destination: .recent,
                        symbolName: "clock",
                        title: "最近添加"
                    )
                    sidebarRow(
                        destination: .trash,
                        symbolName: "trash",
                        title: "废纸篓"
                    )
                }

                sidebarSectionDivider

                // Section: Pinterest Infinite Exploration Space
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("灵感发现")
                    sidebarRow(
                        destination: .pinterest,
                        symbolName: "sparkles",
                        title: "Pinterest 空间"
                    )
                }

                sidebarSectionDivider

                // Section 2: Moodboards
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        sectionHeader("情绪板")
                        Spacer()
                        Button {
                            coordinator.presentMoodboardGenerator(entry: .prompt)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text("快速生成")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))
                        .help("4 入口 10 秒快速生成情绪板")
                    }
                    .padding(.trailing, 10)

                    sidebarRow(
                        destination: .moodboardsHome,
                        symbolName: "rectangle.3.group",
                        title: "所有情绪板",
                        badgeCount: moodboards.boards.count
                    )

                    ForEach(moodboards.boards) { board in
                        let isActiveTarget = coordinator.activeMoodboardID == board.id
                        sidebarRow(
                            destination: .moodboard(board.id),
                            symbolName: "sparkles.rectangle.stack",
                            title: board.title,
                            badgeCount: board.itemCount,
                            isActiveMoodboard: isActiveTarget,
                            isPinnedOffline: board.pinnedOffline,
                            isDropHighlighted: dropTargetedBoardID == board.id
                        )
                        .onDrop(
                            of: [.plainText, .fileURL, .url, .image],
                            isTargeted: Binding(
                                get: { dropTargetedBoardID == board.id },
                                set: { targeted in
                                    dropTargetedBoardID = targeted ? board.id : (dropTargetedBoardID == board.id ? nil : dropTargetedBoardID)
                                }
                            )
                        ) { providers in
                            handleDrop(providers: providers, folderID: nil, boardID: board.id)
                        }
                        .contextMenu {
                            Button(isActiveTarget ? "已是当前活跃情绪板" : "设为当前活跃情绪板（刘海直投目标）") {
                                coordinator.activeMoodboardID = board.id
                                coordinator.showToast("已锁定「\(board.title)」为刘海活跃情绪板", icon: "checkmark.circle.fill")
                            }
                            Button {
                                let nextPinned = !board.pinnedOffline
                                Task {
                                    await moodboards.togglePinnedOffline(id: board.id)
                                    coordinator.showToast(
                                        nextPinned ? "整板素材将始终保留在本地" : "已取消整板始终保留在本地",
                                        icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                                    )
                                }
                            } label: {
                                Label(
                                    board.pinnedOffline ? "取消始终保留在本地" : "始终保留整板在本地",
                                    systemImage: board.pinnedOffline ? "icloud" : "arrow.down.circle"
                                )
                            }
                            Divider()
                            Button("删除情绪板…", role: .destructive) {
                                pendingDeleteBoard = board
                            }
                        }
                    }
                }

                sidebarSectionDivider

                // Section 3: Smart Folders
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        sectionHeader("智能文件夹")
                        Spacer()
                        Button {
                            coordinator.editingSmartFolder = nil
                            coordinator.isSmartFolderEditorPresented = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("新建智能文件夹（按标签/描述/颜色/类型自动归集）")
                    }
                    .padding(.trailing, 10)

                    if library.smartFolders.isEmpty {
                        Button {
                            coordinator.editingSmartFolder = nil
                            coordinator.isSmartFolderEditorPresented = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.badge.gearshape")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                Text("定义规则自动归集素材…")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(library.smartFolders) { sf in
                            sidebarRow(
                                destination: .smartFolder(sf.id),
                                symbolName: "folder.badge.gearshape",
                                title: sf.name,
                                badgeCount: library.matchingCount(for: sf),
                                dotColorHex: sf.colorHex
                            )
                            .contextMenu {
                                Button {
                                    coordinator.editingSmartFolder = sf
                                    coordinator.isSmartFolderEditorPresented = true
                                } label: {
                                    Label("编辑筛选规则…", systemImage: "slider.horizontal.3")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    Task {
                                        await library.deleteSmartFolder(id: sf.id)
                                        if coordinator.selectedDestination == .smartFolder(sf.id) {
                                            onSelectDestination(.allItems)
                                        }
                                        coordinator.showToast("已删除智能文件夹「\(sf.name)」", icon: "trash")
                                    }
                                } label: {
                                    Label("删除智能文件夹", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                sidebarSectionDivider

                // Section 4: Hierarchical Folders (with drag-to-reorder, drag-to-nest & external Finder folder drop)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        sectionHeader("文件夹")
                        Spacer()
                        if library.folders.count > 1 {
                            Menu {
                                Button("按名称 A→Z 排序") {
                                    Task { await sortRootFoldersAlphabetically() }
                                }
                                Button("按素材数量降序") {
                                    Task { await sortRootFoldersByCount() }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .frame(width: 20)
                            .help("排序文件夹")
                        }
                        if let onImportMaterialPackage {
                            Button {
                                onImportMaterialPackage()
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("导入素材包 / PureRef 场景 (.eaglepack / .library / .pur)… (⌘⇧I)")
                        }
                        Button {
                            toggleFolderCreation(target: .root)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("新建文件夹（也可直接拖入外部文件夹、.eaglepack 素材包或 .pur 场景）")
                    }
                    .padding(.trailing, 10)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(dropTargetedFolderRoot ? activeAccent.opacity(0.14) : Color.clear)
                            .padding(.horizontal, 8)
                    )
                    .onDrop(of: [.plainText, .fileURL, .url], isTargeted: $dropTargetedFolderRoot) { providers in
                        handleFolderHeaderDrop(providers: providers)
                    }

                    if creationTarget == .root {
                        inlineFolderCreatorRow(placeholder: "新文件夹名称", depth: 0)
                    }

                    if library.folders.isEmpty && creationTarget == nil {
                        Text("暂无文件夹，点击 + 或拖入文件夹 / .eaglepack 素材包")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onDrop(of: [.fileURL, .url], isTargeted: $dropTargetedFolderRoot) { providers in
                                handleFolderHeaderDrop(providers: providers)
                            }
                    } else {
                        let tree = visibleFolderTree
                        let rootFolderCount = library.childFolders(of: nil).count
                        let activeSlotRowIdx = activeFolderDropSlotRowIndex(in: tree)
                        ForEach(Array(tree.enumerated()), id: \.element.id) { rowIndex, node in
                            let folder = node.folder
                            let ripple: (offset: CGFloat, delay: Double) = {
                                guard let slotIdx = activeSlotRowIdx, !reduceMotion else { return (0, 0) }
                                if rowIndex < slotIdx {
                                    let dist = (slotIdx - 1) - rowIndex
                                    return (
                                        -CharkleMotion.rippleOffset(distance: dist, amplitude: 4.5),
                                        CharkleMotion.rippleDelay(distance: dist)
                                    )
                                } else {
                                    let dist = rowIndex - slotIdx
                                    return (
                                        CharkleMotion.rippleOffset(distance: dist, amplitude: 4.5),
                                        CharkleMotion.rippleDelay(distance: dist)
                                    )
                                }
                            }()
                            // Top insertion slot for reordering / dropping an external folder right before this row
                            folderDropInsertionSlot(
                                parentID: folder.parentID,
                                insertIndex: node.siblingIndex,
                                depth: node.depth
                            )

                            if renamingFolderID == folder.id {
                                inlineFolderRenameRow(folder: folder, depth: node.depth)
                            } else {
                                folderTreeRow(node, visibleTree: tree)
                                    .offset(y: ripple.offset)
                                    .animation(
                                        CharkleMotion.accessible(CharkleMotion.uiSpring, reduced: reduceMotion)
                                            .delay(ripple.delay),
                                        value: dropTargetedSlot
                                    )
                            }

                            if creationTarget == .subfolder(folder.id) {
                                inlineFolderCreatorRow(placeholder: "子文件夹名称", depth: node.depth + 1)
                            }

                            // Trailing slot after the last child sibling inside a nested subfolder
                            if folder.parentID != nil && node.siblingIndex == node.siblingCount - 1 && !node.isExpanded {
                                folderDropInsertionSlot(
                                    parentID: folder.parentID,
                                    insertIndex: node.siblingCount,
                                    depth: node.depth
                                )
                            }
                        }

                        // Dedicated bottom trailing slot for top-level folders (always present even when the last root folder is expanded)
                        folderDropInsertionSlot(
                            parentID: nil,
                            insertIndex: rootFolderCount,
                            depth: 0,
                            isBottomRootZone: true
                        )
                    }
                }

                    // Section 5: Smart Capped Tags (Top 10 Most Used + up to 5 Recent Frequent + "View All" Popover)
                    if !library.tagCounts.isEmpty {
                        sidebarSectionDivider
                        sidebarTagsSection
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 14)
                .charkleCleanScrollbars(hidden: true)
            }
            .scrollIndicators(.hidden)
            .clipped()

            CharkleHairlineDivider()

            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                    coordinator.openSettings()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14.5, weight: coordinator.isSettingsPresented ? .semibold : .medium))
                        .symbolVariant(coordinator.isSettingsPresented ? .fill : .none)
                        .foregroundStyle(coordinator.isSettingsPresented ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                        .frame(width: 18, height: 18)
                    Text("设置")
                        .font(.system(size: 12.5, weight: coordinator.isSettingsPresented ? .semibold : .medium))
                        .foregroundStyle(coordinator.isSettingsPresented ? Color.primary : Color.primary.opacity(0.84))
                    Spacer()
                    Text("⌘,")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    coordinator.isSettingsPresented
                        ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .help("打开 Charkle 设置 (⌘,)")
        }
    }

    // MARK: - Smart Capped Tags Section & Searchable All-Tags Popover

    private var sidebarTagsSection: some View {
        let recentFive = library.recentFrequentSidebarTags
        let recentSet = Set(recentFive.map { $0.name.lowercased() })
        let topTen = library.topTenSidebarTags
        let topNonDuplicate = topTen.filter { !recentSet.contains($0.name.lowercased()) }
        var displayedNames = Set(recentFive.map { $0.name.lowercased() })
        for t in topNonDuplicate { displayedNames.insert(t.name.lowercased()) }

        // Always keep an actively selected tag visible if it isn't in top 10 / recent 5
        var extraSelectedTag: TagCount?
        if case .tag(let selectedTagName) = coordinator.selectedDestination,
           !displayedNames.contains(selectedTagName.lowercased()) {
            extraSelectedTag = library.tagCounts.first(where: { $0.name.caseInsensitiveCompare(selectedTagName) == .orderedSame })
        }

        let hiddenCount = max(0, library.tagCounts.count - (recentFive.count + topNonDuplicate.count + (extraSelectedTag == nil ? 0 : 1)))

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                        isTagsSectionExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        sectionHeader("标签")
                        Text("\(library.tagCounts.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 4)
                        Spacer(minLength: 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isTagsSectionExpanded ? "收起标签栏" : "展开常用标签")

                Button {
                    isAllTagsPopoverPresented = true
                } label: {
                    Text("全部")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .popover(isPresented: $isAllTagsPopoverPresented, arrowEdge: .trailing) {
                    allTagsPopoverContent
                        .environment(\.charkleAccentSource, accentSource)
                        .tint(activeAccent)
                }
                .help("查看并搜索全部 \(library.tagCounts.count) 个标签")

                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                        isTagsSectionExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isTagsSectionExpanded ? 90 : 0))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
                .help(isTagsSectionExpanded ? "收起标签栏" : "展开常用标签")
            }

            if isTagsSectionExpanded {
                if let extra = extraSelectedTag {
                    sidebarRow(
                        destination: .tag(extra.name),
                        symbolName: "tag",
                        title: "#\(extra.name)",
                        badgeCount: extra.count
                    )
                }

                if !recentFive.isEmpty {
                    Text("最近常用")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 2)
                        .padding(.bottom, 2)
                    ForEach(recentFive) { tag in
                        sidebarRow(
                            destination: .tag(tag.name),
                            symbolName: "tag",
                            title: "#\(tag.name)",
                            badgeCount: tag.count
                        )
                    }
                }

                if !topNonDuplicate.isEmpty {
                    if !recentFive.isEmpty {
                        Text("高频标签")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                    }
                    ForEach(topNonDuplicate) { tag in
                        sidebarRow(
                            destination: .tag(tag.name),
                            symbolName: "tag",
                            title: "#\(tag.name)",
                            badgeCount: tag.count
                        )
                    }
                }

                if hiddenCount > 0 {
                    Button {
                        isAllTagsPopoverPresented = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text("查看全部 \(library.tagCounts.count) 个标签（已隐藏 \(hiddenCount) 个）")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var allTagsPopoverContent: some View {
        let query = allTagsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = library.tagCounts.filter {
            query.isEmpty || $0.name.lowercased().contains(query)
        }.sorted { lhs, rhs in
            if allTagsSortByCount {
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                TextField("搜索全部 \(library.tagCounts.count) 个标签…", text: $allTagsSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !allTagsSearchQuery.isEmpty {
                    Button {
                        allTagsSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    allTagsSortByCount.toggle()
                } label: {
                    Text(allTagsSortByCount ? "按数量" : "按名称")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(CharkleButtonStyle(.subtle, size: .xs, cornerRadius: 999))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            CharkleHairlineDivider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { tag in
                        let selected = coordinator.selectedDestination == .tag(tag.name)
                        Button {
                            onSelectDestination(.tag(tag.name))
                            isAllTagsPopoverPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "tag")
                                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                                    .symbolVariant(selected ? .fill : .none)
                                    .foregroundStyle(selected ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                                    .frame(width: 16, height: 16)
                                Text("#\(tag.name)")
                                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(tag.count)")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(
                                selected ? CharkleTheme.accentSoft(for: colorScheme, source: accentSource) : Color.clear,
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 280)
    }

    // MARK: - Folder Insertion Drop Slot (Drag-to-Reorder + External Folder Drop at Position)

    private func activeFolderDropSlotRowIndex(in tree: [FolderTreeNode]) -> Int? {
        guard let slot = dropTargetedSlot else { return nil }
        if let matchIdx = tree.firstIndex(where: {
            $0.folder.parentID == slot.parentID && $0.siblingIndex == slot.index
        }) {
            return matchIdx
        }
        if let lastSiblingIdx = tree.lastIndex(where: { $0.folder.parentID == slot.parentID }) {
            return lastSiblingIdx + 1
        }
        return tree.count
    }

    private func folderDropInsertionSlot(
        parentID: UUID?,
        insertIndex: Int,
        depth: Int,
        isBottomRootZone: Bool = false
    ) -> some View {
        let slotKey = FolderSlotKey(parentID: parentID, index: insertIndex)
        let isTargeted = dropTargetedSlot == slotKey
        let indent = CGFloat(min(depth, 5)) * 14
        let restHeight: CGFloat = isBottomRootZone ? 14 : 6
        let activeHeight: CGFloat = isBottomRootZone ? 16 : 10

        return ZStack(alignment: isBottomRootZone ? .topLeading : .leading) {
            Color.clear
                .frame(height: isTargeted ? activeHeight : restHeight)
            if isTargeted {
                HStack(spacing: 0) {
                    Circle()
                        .fill(activeAccent)
                        .frame(width: 6, height: 6)
                    Rectangle()
                        .fill(activeAccent)
                        .frame(height: 2)
                }
                .padding(.leading, 18 + indent)
                .padding(.trailing, 12)
                .padding(.top, isBottomRootZone ? 4 : 0)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [.plainText, .fileURL, .url],
            isTargeted: Binding(
                get: { dropTargetedSlot == slotKey },
                set: { targeted in
                    withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                        if targeted {
                            dropTargetedSlot = slotKey
                        } else if dropTargetedSlot == slotKey {
                            dropTargetedSlot = nil
                        }
                    }
                }
            )
        ) { providers in
            handleFolderSlotDrop(providers: providers, parentID: parentID, insertIndex: insertIndex)
        }
    }

    // MARK: - Folder Tree Row & Inline Creator / Renamer (with Click-Outside Dismiss)

    private func folderTreeRow(_ node: FolderTreeNode, visibleTree: [FolderTreeNode]) -> some View {
        let folder = node.folder
        let destination: SidebarDestination = .folder(folder.id)
        let isDestinationSelected = coordinator.selectedDestination == destination
        let isMultiSelected = selectedFolderIDs.contains(folder.id)
        let isSelected = isDestinationSelected || isMultiSelected
        let isDropHighlighted = dropTargetedFolderID == folder.id
        let isPinned = library.isFolderSubtreePinnedOffline(folder.id)
        let rowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let indent = CGFloat(min(node.depth, 5)) * 14

        let targetFolderIDs: [UUID] = {
            if selectedFolderIDs.contains(folder.id) && selectedFolderIDs.count > 1 {
                return visibleTree.map(\.folder.id).filter { selectedFolderIDs.contains($0) }
            }
            return [folder.id]
        }()

        return SidebarFolderRowHoverWrapper { isHovered in
            HStack(spacing: 2) {
                // Note: Use `.onTapGesture` instead of `Button` on the row and chevron so macOS SwiftUI `.onDrag`
                // initiates cleanly from ANY point on the row (including top-level parent folders with children).
                if node.hasChildren {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                if expandedFolderIDs.contains(folder.id) {
                                    expandedFolderIDs.remove(folder.id)
                                } else {
                                    expandedFolderIDs.insert(folder.id)
                                }
                            }
                        }
                } else {
                    Spacer().frame(width: 22)
                }

                HStack(spacing: 8) {
                    CharkleFolderIcon(
                        colorHex: folder.colorHex,
                        customSymbol: folder.customSymbol,
                        size: 18,
                        isActive: isSelected
                    )
                    Text(folder.name)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))
                        .lineLimit(1)
                    Spacer(minLength: 4)

                    if isPinned {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("文件夹素材始终保留在本地")
                    }

                    let displayCount = library.subtreeAssetCount(for: folder.id)
                    if displayCount > 0 {
                        Text("\(displayCount)")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleFolderRowClick(folder: folder)
                }

                if isHovered {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleFolderCreation(target: .subfolder(folder.id))
                        }
                        .help("在「\(folder.name)」内新建子文件夹")
                }
            }
            .padding(.leading, 4 + indent)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background {
                if isMultiSelected && selectedFolderIDs.count > 1 {
                    rowShape
                        .fill(activeAccent.opacity(colorScheme == .dark ? 0.24 : 0.16))
                        .overlay(rowShape.strokeBorder(activeAccent.opacity(0.55), lineWidth: 1))
                } else if isDestinationSelected {
                    rowShape
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                        .matchedGeometryEffect(id: "sidebar-expanded-selection-pill", in: expandedSelectionNamespace)
                } else if isDropHighlighted {
                    rowShape
                        .fill(activeAccent.opacity(0.16))
                        .overlay(rowShape.strokeBorder(activeAccent, lineWidth: 1.5))
                }
            }
            .contentShape(rowShape)
            .onDrag {
                NSItemProvider(object: CharkleDragIdentifiers.encode(folderIDs: targetFolderIDs) as NSString)
            } preview: {
                HStack(spacing: 7) {
                    CharkleFolderIcon(
                        colorHex: folder.colorHex,
                        customSymbol: folder.customSymbol,
                        size: 16,
                        isActive: true
                    )
                    Text(targetFolderIDs.count > 1 ? "\(folder.name) 等 \(targetFolderIDs.count) 个文件夹" : folder.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .onDrop(
                of: [.plainText, .fileURL, .url, .image],
                isTargeted: Binding(
                    get: { dropTargetedFolderID == folder.id },
                    set: { targeted in
                        dropTargetedFolderID = targeted ? folder.id : (dropTargetedFolderID == folder.id ? nil : dropTargetedFolderID)
                    }
                )
            ) { providers in
                handleDrop(providers: providers, folderID: folder.id, boardID: nil)
            }
            .padding(.horizontal, 8)
            .popover(
                isPresented: Binding(
                    get: { customizingFolderID == folder.id },
                    set: { if !$0 && customizingFolderID == folder.id { customizingFolderID = nil } }
                ),
                arrowEdge: .trailing
            ) {
                FolderCustomizationPopover(folder: folder) { colorHex, customSymbol in
                    Task {
                        for fid in targetFolderIDs {
                            await library.updateFolderAppearance(id: fid, colorHex: colorHex, customSymbol: customSymbol)
                        }
                    }
                }
                .environment(\.charkleAccentSource, accentSource)
                .tint(activeAccent)
            }
        }
        .contextMenu {
            let isBatch = targetFolderIDs.count > 1
            let batchLabel = isBatch ? "（已选 \(targetFolderIDs.count) 个文件夹）" : ""

            if !isBatch && !library.cutAssetIDs.isEmpty {
                Button {
                    Task {
                        let count = await library.pasteCutAssets(toFolderID: folder.id)
                        coordinator.showToast("已将 \(count) 项素材移至「\(folder.name)」", icon: "folder")
                    }
                } label: {
                    Label("粘贴移动至此文件夹（\(library.cutAssetIDs.count) 项）", systemImage: "doc.on.clipboard")
                }
                Divider()
            }

            if !isBatch {
                Button {
                    toggleFolderCreation(target: .subfolder(folder.id))
                } label: {
                    Label("新建子文件夹…", systemImage: "folder.badge.plus")
                }
                Button("重命名…") {
                    renameDraft = folder.name
                    renamingFolderID = folder.id
                    DispatchQueue.main.async {
                        isRenameFieldFocused = true
                    }
                }
                if let onExportFolderToPureRef {
                    Menu {
                        Button {
                            onExportFolderToPureRef(folder, true)
                        } label: {
                            Label("在 PureRef 中打开", systemImage: "arrow.up.forward.app")
                        }
                        Button {
                            onExportFolderToPureRef(folder, false)
                        } label: {
                            Label("导出为 PureRef (.pur)…", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("发送到 PureRef", systemImage: "square.grid.2x2")
                    }
                }
                if let onOpenSmartDeduplication {
                    Button {
                        onOpenSmartDeduplication(folder.id)
                    } label: {
                        Label("在此文件夹中智能去重…", systemImage: "square.on.square.dashed")
                    }
                }
            }

            if folder.parentID != nil || isBatch {
                Button {
                    Task {
                        for fid in targetFolderIDs {
                            _ = await library.moveFolder(id: fid, newParentID: nil, insertAtIndex: nil)
                        }
                        coordinator.showToast(isBatch ? "已将 \(targetFolderIDs.count) 个文件夹移至顶层" : "已将「\(folder.name)」移至顶层", icon: "folder")
                    }
                } label: {
                    Label("移至顶层目录\(batchLabel)", systemImage: "arrow.up.left.square")
                }
            }

            Divider()

            // Offline Pin / Clear Offline Cache
            Button {
                Task {
                    let count = await library.setFoldersPinnedOffline(targetFolderIDs, pinned: true)
                    coordinator.showToast("已将 \(count) 项素材设为始终保留在本地", icon: "arrow.down.circle.fill")
                }
            } label: {
                Label("始终保留在本地\(batchLabel)", systemImage: "arrow.down.circle.fill")
            }

            Button {
                Task {
                    let count = await library.setFoldersPinnedOffline(targetFolderIDs, pinned: false)
                    coordinator.showToast("已清理 \(count) 项素材的离线缓存锁定", icon: "icloud")
                }
            } label: {
                Label("清理离线缓存\(batchLabel)", systemImage: "icloud")
            }

            Divider()

            // macOS-style Folder Color Quick Submenu + Customize Folder Popover
            Menu {
                let isDarkMenu = colorScheme == .dark
                Button {
                    Task {
                        for fid in targetFolderIDs {
                            let sym = library.folders.first(where: { $0.id == fid })?.customSymbol
                            await library.updateFolderAppearance(id: fid, colorHex: nil, customSymbol: sym)
                        }
                    }
                } label: {
                    Label {
                        Text(folder.colorHex == nil ? "恢复默认颜色  ✓" : "恢复默认颜色")
                    } icon: {
                        Image(nsImage: CharkleIconCache.shared.menuFolderIcon(colorHex: nil, isDark: isDarkMenu))
                    }
                }
                Divider()
                ForEach(FolderCustomizationPopover.macOSFolderColors, id: \.hex) { preset in
                    let isCurrent = folder.colorHex?.caseInsensitiveCompare(preset.hex) == .orderedSame
                    Button {
                        Task {
                            for fid in targetFolderIDs {
                                let sym = library.folders.first(where: { $0.id == fid })?.customSymbol
                                await library.updateFolderAppearance(id: fid, colorHex: preset.hex, customSymbol: sym)
                            }
                        }
                    } label: {
                        Label {
                            Text(isCurrent ? "\(preset.name)  ✓" : preset.name)
                        } icon: {
                            Image(nsImage: CharkleIconCache.shared.menuFolderIcon(colorHex: preset.hex, isDark: isDarkMenu))
                        }
                    }
                }
            } label: {
                Label("更改文件夹颜色\(batchLabel)", systemImage: "paintpalette")
            }

            Button {
                customizingFolderID = folder.id
            } label: {
                Label("自定义文件夹…", systemImage: "tag")
            }

            Divider()

            Button {
                Task {
                    for fid in targetFolderIDs {
                        await library.deleteFolder(id: fid, trashContents: false)
                    }
                    selectedFolderIDs.subtract(targetFolderIDs)
                    if case .folder(let currentID) = coordinator.selectedDestination,
                       !library.folders.contains(where: { $0.id == currentID }) {
                        onSelectDestination(.allItems)
                    }
                    coordinator.showToast(
                        isBatch ? "已删除 \(targetFolderIDs.count) 个文件夹，素材已退回收件箱" : "已删除「\(folder.name)」，素材已退回收件箱",
                        icon: "tray.and.arrow.down"
                    )
                }
            } label: {
                Label("删除文件夹（素材退回收件箱）\(batchLabel)", systemImage: "folder.badge.minus")
            }

            Button(role: .destructive) {
                let targets = targetFolderIDs.compactMap { id in library.folders.first(where: { $0.id == id }) }
                pendingDeleteWithContentsFolders = targets
            } label: {
                Label("删除文件夹及其中素材…\(batchLabel)", systemImage: "trash")
            }
        }
    }

    private func handleFolderRowClick(folder: FolderRecord) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selectedFolderIDs.contains(folder.id) {
                selectedFolderIDs.remove(folder.id)
            } else {
                if selectedFolderIDs.isEmpty, case .folder(let currentID) = coordinator.selectedDestination {
                    selectedFolderIDs.insert(currentID)
                }
                selectedFolderIDs.insert(folder.id)
            }
            lastClickedFolderID = folder.id
        } else if mods.contains(.shift), let anchor = lastClickedFolderID {
            let ordered = visibleFolderTree.map(\.folder.id)
            if let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: folder.id) {
                let range = min(a, b)...max(a, b)
                selectedFolderIDs.formUnion(ordered[range])
            } else {
                selectedFolderIDs.insert(folder.id)
            }
        } else {
            selectedFolderIDs = [folder.id]
            lastClickedFolderID = folder.id
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                onSelectDestination(.folder(folder.id))
            }
        }
    }

    private func inlineFolderCreatorRow(placeholder: String, depth: Int) -> some View {
        let indent = CGFloat(min(depth, 5)) * 14
        return HStack(spacing: 6) {
            TextField(placeholder, text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($isNewFolderFieldFocused)
                .onSubmit { commitNewFolder() }
                .onExitCommand { cancelFolderCreation() }
            Button("创建") { commitNewFolder() }
                .buttonStyle(CharkleButtonStyle(.accent, size: .xs))
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 12 + indent)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(
            ClickOutsideDismissAnchor {
                cancelFolderCreation()
            }
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        .onAppear {
            DispatchQueue.main.async {
                isNewFolderFieldFocused = true
            }
        }
    }

    private func inlineFolderRenameRow(folder: FolderRecord, depth: Int) -> some View {
        let indent = CGFloat(min(depth, 5)) * 14
        return HStack(spacing: 6) {
            TextField("重命名", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($isRenameFieldFocused)
                .onSubmit { commitFolderRename(folderID: folder.id) }
                .onExitCommand { renamingFolderID = nil }
            Button("好") { commitFolderRename(folderID: folder.id) }
                .buttonStyle(CharkleButtonStyle(.standard, size: .xs))
        }
        .padding(.leading, 12 + indent)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(
            ClickOutsideDismissAnchor {
                renamingFolderID = nil
            }
        )
        .onAppear {
            DispatchQueue.main.async {
                isRenameFieldFocused = true
            }
        }
    }

    private func toggleFolderCreation(target: FolderCreationTarget) {
        if creationTarget == target || (lastDismissedTarget == target && Date().timeIntervalSince(lastDismissedAt) < 0.30) {
            cancelFolderCreation()
            return
        }
        if case .subfolder(let parentID) = target {
            expandedFolderIDs.insert(parentID)
        }
        withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
            newFolderName = ""
            creationTarget = target
        }
    }

    private func cancelFolderCreation() {
        guard let current = creationTarget else { return }
        lastDismissedTarget = current
        lastDismissedAt = Date()
        withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
            creationTarget = nil
            newFolderName = ""
        }
        isNewFolderFieldFocused = false
    }

    private func commitFolderRename(folderID: UUID) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingFolderID = nil
        isRenameFieldFocused = false
        guard !name.isEmpty else { return }
        Task { await library.renameFolder(id: folderID, newName: name) }
    }

    private func seedInitialExpansionIfNeeded() {
        guard !didSeedInitialExpansion, !library.folders.isEmpty else { return }
        didSeedInitialExpansion = true
        let parentsWithChildren = Set(library.folders.compactMap(\.parentID))
        expandedFolderIDs.formUnion(parentsWithChildren)
    }

    private func expandAncestors(of folderID: UUID) {
        for crumb in library.folderBreadcrumbs(for: folderID) where crumb.id != folderID {
            expandedFolderIDs.insert(crumb.id)
        }
    }

    private func sortRootFoldersAlphabetically() async {
        let sorted = library.childFolders(of: nil).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for (idx, f) in sorted.enumerated() {
            _ = await library.moveFolder(id: f.id, newParentID: nil, insertAtIndex: idx)
        }
        coordinator.showToast("文件夹已按名称排好序", icon: "arrow.up.arrow.down")
    }

    private func sortRootFoldersByCount() async {
        let sorted = library.childFolders(of: nil).sorted {
            let lhsCount = library.subtreeAssetCount(for: $0.id)
            let rhsCount = library.subtreeAssetCount(for: $1.id)
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for (idx, f) in sorted.enumerated() {
            _ = await library.moveFolder(id: f.id, newParentID: nil, insertAtIndex: idx)
        }
        coordinator.showToast("文件夹已按素材数量排好序", icon: "arrow.up.arrow.down")
    }
}

/// Isolates per-row hover state so hovering over folders in the sidebar only re-renders the
/// entered/exited row instead of invalidating the entire `SidebarView` tree.
private struct SidebarFolderRowHoverWrapper<Content: View>: View {
    @Environment(\.charkleOverlayInteractionSuspended) private var isOverlayInteractionSuspended
    @State private var isHovered: Bool = false
    let content: (Bool) -> Content

    var body: some View {
        content(isHovered && !isOverlayInteractionSuspended)
            .onHover { hovering in
                let next = isOverlayInteractionSuspended ? false : hovering
                if isHovered != next {
                    isHovered = next
                }
            }
            .onChange(of: isOverlayInteractionSuspended) { _, suspended in
                if suspended && isHovered {
                    isHovered = false
                }
            }
    }
}

/// Invisible AppKit anchor attached behind an inline editor row; automatically dismisses
/// whenever a left or right mouse click lands outside the row's bounds.
private struct ClickOutsideDismissAnchor: NSViewRepresentable {
    let onClickOutside: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onClickOutside = onClickOutside
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onClickOutside: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let win = self.window else { return event }
                if event.window !== win {
                    self.onClickOutside?()
                    return event
                }
                let localPoint = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(localPoint) {
                    self.onClickOutside?()
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        isolated deinit {
            stopMonitoring()
        }
    }
}

/// Native macOS translucent sidebar surface (`NSVisualEffectView(.sidebar)`) without `NavigationSplitView`'s
/// hidden-titlebar scroll pocket hit-testing offset, falling back to calibrated neutral solid surface under Reduce Transparency.
public struct CharkleSidebarMaterialBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
        if reduceTransparency {
            colorScheme == .dark ? Color(charkleHex: "#17191D") : Color(charkleHex: "#F2F1EE")
        } else {
            SidebarVisualEffectView()
        }
    }
}

private struct SidebarVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
    }
}

extension SidebarView {

    private var sidebarSectionDivider: some View {
        CharkleHairlineDivider(horizontalInset: 14)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary.opacity(0.82))
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
    }

    private func sidebarRow(
        destination: SidebarDestination,
        symbolName: String,
        title: String,
        badgeCount: Int? = nil,
        emphasizeBadge: Bool = false,
        isActiveMoodboard: Bool = false,
        isPinnedOffline: Bool = false,
        isDropHighlighted: Bool = false,
        dotColorHex: String? = nil
    ) -> some View {
        let isSelected = coordinator.selectedDestination == destination
        let rowShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)

        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                onSelectDestination(destination)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))
                    .lineLimit(1)

                if let hex = dotColorHex {
                    Circle()
                        .fill(Color(charkleHex: hex))
                        .frame(width: 7, height: 7)
                }

                Spacer(minLength: 4)

                if isActiveMoodboard {
                    Circle()
                        .fill(CharkleTheme.positive(for: colorScheme))
                        .frame(width: 6, height: 6)
                        .help("当前活跃情绪板（刘海直投目标）")
                }

                if isPinnedOffline {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("已始终保留在本地")
                }

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: emphasizeBadge ? .semibold : .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(
                            emphasizeBadge
                                ? CharkleTheme.accentButtonForeground(for: colorScheme, source: accentSource)
                                : CharkleTheme.secondaryInk(for: colorScheme)
                        )
                        .padding(.horizontal, emphasizeBadge ? 6 : 4)
                        .padding(.vertical, emphasizeBadge ? 2 : 1)
                        .background {
                            if emphasizeBadge {
                                Capsule(style: .continuous)
                                    .fill(CharkleTheme.accentButtonFill(for: colorScheme, source: accentSource))
                            }
                        }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if isSelected {
                    rowShape
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                        .matchedGeometryEffect(id: "sidebar-expanded-selection-pill", in: expandedSelectionNamespace)
                } else if isDropHighlighted {
                    rowShape
                        .fill(activeAccent.opacity(0.16))
                        .overlay(rowShape.strokeBorder(activeAccent, lineWidth: 1.5))
                }
            }
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func commitNewFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelFolderCreation()
            return
        }
        let parentID = creationTarget?.parentID
        newFolderName = ""
        creationTarget = nil
        isNewFolderFieldFocused = false
        Task {
            if let created = await library.createFolder(name: trimmed, parentID: parentID) {
                if let parentID {
                    expandedFolderIDs.insert(parentID)
                }
                coordinator.showToast("已创建文件夹「\(created.name)」", icon: "folder.badge.plus")
            }
        }
    }

    private func handleFolderHeaderDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var draggedFolderIDs: [UUID] = []
            var internalAssetIDs: [UUID] = []
            var externalInputs: [CaptureInput] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadText(provider) {
                    if let fids = CharkleDragIdentifiers.decodeFolderIDs(from: str) {
                        draggedFolderIDs.append(contentsOf: fids)
                        continue
                    }
                    if let aids = CharkleDragIdentifiers.decodeAssetIDs(from: str) {
                        internalAssetIDs.append(contentsOf: aids)
                        continue
                    }
                }
                // Short-circuit `.fileURL` providers once internal folder/asset IDs are decoded so
                // internal gallery drags NEVER re-import cached thumbnails as duplicate assets.
                guard draggedFolderIDs.isEmpty && internalAssetIDs.isEmpty else { continue }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider, type: .fileURL) {
                    externalInputs.append(.fileURL(url))
                }
            }
            if !draggedFolderIDs.isEmpty {
                for (offset, fid) in draggedFolderIDs.enumerated() {
                    _ = await library.moveFolder(id: fid, newParentID: nil, insertAtIndex: offset)
                }
                coordinator.showToast("已将 \(draggedFolderIDs.count) 个文件夹移至顶层", icon: "folder")
            } else if !internalAssetIDs.isEmpty {
                return
            } else if !externalInputs.isEmpty {
                let beforeIDs = Set(library.folders.map(\.id))
                let imported = await library.ingest(externalInputs, targetFolderID: nil)
                let newRootFolders = library.folders.filter { !beforeIDs.contains($0.id) && $0.parentID == nil }
                if !newRootFolders.isEmpty {
                    await sortRootFoldersAlphabetically()
                }
                if imported.isEmpty && newRootFolders.isEmpty {
                    coordinator.showToast(library.lastError ?? "导入文件夹失败", icon: "exclamationmark.triangle", tone: .warning)
                } else {
                    coordinator.showToast("已导入文件夹并整理 \(imported.count) 项素材", icon: "folder.badge.plus", tone: .success)
                }
            }
        }
        return true
    }

    private func handleFolderSlotDrop(providers: [NSItemProvider], parentID: UUID?, insertIndex: Int) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var draggedFolderIDs: [UUID] = []
            var internalAssetIDs: [UUID] = []
            var externalInputs: [CaptureInput] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadText(provider) {
                    if let fids = CharkleDragIdentifiers.decodeFolderIDs(from: str) {
                        draggedFolderIDs.append(contentsOf: fids)
                        continue
                    }
                    if let aids = CharkleDragIdentifiers.decodeAssetIDs(from: str) {
                        internalAssetIDs.append(contentsOf: aids)
                        continue
                    }
                }
                // Short-circuit `.fileURL` providers once internal folder/asset IDs are decoded so
                // internal gallery drags NEVER re-import cached thumbnails as duplicate assets.
                guard draggedFolderIDs.isEmpty && internalAssetIDs.isEmpty else { continue }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider, type: .fileURL) {
                    externalInputs.append(.fileURL(url))
                }
            }

            if !draggedFolderIDs.isEmpty {
                var movedAny = false
                var runningInsertIndex = insertIndex
                for fid in draggedFolderIDs {
                    let currentSiblings = library.childFolders(of: parentID)
                    let oldIndex = currentSiblings.firstIndex(where: { $0.id == fid })
                    let adjustedIndex: Int
                    if let oldIndex, oldIndex < runningInsertIndex {
                        adjustedIndex = max(0, runningInsertIndex - 1)
                    } else {
                        adjustedIndex = runningInsertIndex
                        runningInsertIndex += 1
                    }
                    if await library.moveFolder(id: fid, newParentID: parentID, insertAtIndex: adjustedIndex) {
                        movedAny = true
                    }
                }
                if movedAny {
                    if let parentID { expandedFolderIDs.insert(parentID) }
                } else if let err = library.lastError {
                    coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                }
            } else if !internalAssetIDs.isEmpty {
                if let parentID {
                    onDropAssetsOntoFolder(internalAssetIDs, parentID)
                }
                return
            } else if !externalInputs.isEmpty {
                let beforeIDs = Set(library.folders.map(\.id))
                let imported = await library.ingest(externalInputs, targetFolderID: parentID)
                let newFolders = library.folders
                    .filter { !beforeIDs.contains($0.id) && $0.parentID == parentID }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                for (offset, folder) in newFolders.enumerated() {
                    _ = await library.moveFolder(id: folder.id, newParentID: parentID, insertAtIndex: insertIndex + offset)
                }
                if let parentID { expandedFolderIDs.insert(parentID) }
                if imported.isEmpty && newFolders.isEmpty {
                    coordinator.showToast(library.lastError ?? "导入目录失败", icon: "exclamationmark.triangle", tone: .warning)
                } else {
                    coordinator.showToast("已按序导入目录（\(imported.count) 项素材）", icon: "folder.badge.plus", tone: .success)
                }
            }
        }
        return true
    }

    private func handleDrop(providers: [NSItemProvider], folderID: UUID?, boardID: UUID?) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var draggedFolderIDs: [UUID] = []
            var internalIDs: [UUID] = []
            var externalInputs: [CaptureInput] = []

            for provider in providers {
                var plainTextCandidate: String?
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadText(provider) {
                    if let fids = CharkleDragIdentifiers.decodeFolderIDs(from: str) {
                        draggedFolderIDs.append(contentsOf: fids)
                        continue
                    }
                    if let ids = CharkleDragIdentifiers.decodeAssetIDs(from: str) {
                        internalIDs.append(contentsOf: ids)
                        continue
                    }
                    plainTextCandidate = str
                }
                // Once internal folder/asset IDs are already recognized from item 0, skip extra `.fileURL`
                // providers attached for external Finder export so internal drags NEVER duplicate files!
                guard draggedFolderIDs.isEmpty && internalIDs.isEmpty else { continue }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider, type: .fileURL) {
                    externalInputs.append(.fileURL(url))
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(provider, type: .url) {
                    if url.isFileURL { externalInputs.append(.fileURL(url)) }
                    else if WebBookmark.isWebURL(url) {
                        externalInputs.append(.webURL(url, title: nil, notes: nil))
                    }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = await loadData(provider, type: .image) {
                    let ext = Self.detectedImageExtension(for: data)
                    externalInputs.append(.imageData(data, suggestedName: "SidebarDrop-\(UUID().uuidString.prefix(8)).\(ext)", sourceURL: nil))
                    continue
                }
                if let text = plainTextCandidate,
                   let webURL = SocialPostURLParser.extractPostURL(from: text)
                    ?? GitHubRepoURLParser.extractRepoURL(from: text)
                    ?? WebURLParser.extractWebURL(from: text) {
                    externalInputs.append(.webURL(webURL, title: nil, notes: nil))
                }
            }

            if !draggedFolderIDs.isEmpty, boardID == nil {
                var movedCount = 0
                for fid in draggedFolderIDs where fid != folderID {
                    if await library.moveFolder(id: fid, newParentID: folderID, insertAtIndex: nil) {
                        movedCount += 1
                    }
                }
                if movedCount > 0 {
                    if let folderID { expandedFolderIDs.insert(folderID) }
                    coordinator.showToast("已移动 \(movedCount) 个文件夹", icon: "folder")
                } else if let err = library.lastError {
                    coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
                }
                return
            }

            if let boardID {
                if !internalIDs.isEmpty {
                    onDropAssetsOntoBoard(internalIDs, boardID)
                } else if !externalInputs.isEmpty {
                    onDropExternalOntoBoard(externalInputs, boardID)
                }
            } else {
                if !internalIDs.isEmpty {
                    onDropAssetsOntoFolder(internalIDs, folderID)
                } else if !externalInputs.isEmpty {
                    onDropExternalOntoFolder(externalInputs, folderID)
                }
            }
        }
        return true
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let s = item as? String { cont.resume(returning: s) }
                else if let d = item as? Data, let s = String(data: d, encoding: .utf8) { cont.resume(returning: s) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let u = item as? URL { cont.resume(returning: u) }
                else if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { cont.resume(returning: u) }
                else if let s = item as? String, let u = URL(string: s) { cont.resume(returning: u) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    private static func detectedImageExtension(for data: Data) -> String {
        let bytes = Array(data.prefix(12))
        if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes.count >= 6, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 { return "webp" }
        if bytes.count >= 4,
           ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)) { return "tiff" }
        return "png"
    }
}

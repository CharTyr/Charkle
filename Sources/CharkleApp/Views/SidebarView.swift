import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Refined translucent macOS Sidebar supporting:
/// - Smooth collapse into an icon-only rail (`56pt` <-> `226pt`)
/// - Custom duotone solid SVG icons (`18–20pt`)
/// - Smart Folders with live rule matching
/// - Hierarchical Folders with in-app drag-to-reorder / drag-to-nest AND external Finder folder drop
/// - Capped Tags section (Top 10 most-used + up to 5 recent frequent + searchable All Tags popover)
public struct SidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let onSelectDestination: (SidebarDestination) -> Void
    public let onDropAssetsOntoFolder: ([UUID], UUID?) -> Void
    public let onDropExternalOntoFolder: ([CaptureInput], UUID?) -> Void
    public let onDropAssetsOntoBoard: ([UUID], UUID) -> Void
    public let onDropExternalOntoBoard: ([CaptureInput], UUID) -> Void

    @Namespace private var selectionIndicatorNamespace

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
    @State private var hoveredFolderID: UUID?
    @State private var selectedFolderIDs: Set<UUID> = []
    @State private var lastClickedFolderID: UUID?
    @State private var customizingFolderID: UUID?
    @State private var pendingDeleteWithContentsFolders: [FolderRecord] = []

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
        onSelectDestination: @escaping (SidebarDestination) -> Void,
        onDropAssetsOntoFolder: @escaping ([UUID], UUID?) -> Void,
        onDropExternalOntoFolder: @escaping ([CaptureInput], UUID?) -> Void,
        onDropAssetsOntoBoard: @escaping ([UUID], UUID) -> Void,
        onDropExternalOntoBoard: @escaping ([CaptureInput], UUID) -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.onSelectDestination = onSelectDestination
        self.onDropAssetsOntoFolder = onDropAssetsOntoFolder
        self.onDropExternalOntoFolder = onDropExternalOntoFolder
        self.onDropAssetsOntoBoard = onDropAssetsOntoBoard
        self.onDropExternalOntoBoard = onDropExternalOntoBoard
    }

    private var visibleFolderTree: [FolderTreeNode] {
        let byParent = Dictionary(grouping: library.folders) { $0.parentID }
        let knownIDs = Set(library.folders.map(\.id))

        func sortedChildren(of parentID: UUID?) -> [FolderRecord] {
            (byParent[parentID] ?? []).sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }

        var nodes: [FolderTreeNode] = []
        var visited = Set<UUID>()

        func visit(parentID: UUID?, depth: Int) {
            let childrenList = sortedChildren(of: parentID)
            for (idx, folder) in childrenList.enumerated() where visited.insert(folder.id).inserted {
                let sub = byParent[folder.id] ?? []
                let hasChildren = !sub.isEmpty
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

        for folder in library.folders where !visited.contains(folder.id) && (folder.parentID == nil || !knownIDs.contains(folder.parentID!)) {
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
            } else {
                expandedSidebarBody
            }
        }
        .onAppear {
            seedInitialExpansionIfNeeded()
        }
        .onChange(of: library.folders) { _, _ in
            seedInitialExpansionIfNeeded()
        }
        .onChange(of: coordinator.selectedDestination) { _, newDest in
            if case .folder(let folderID) = newDest {
                expandAncestors(of: folderID)
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
    }

    // MARK: - Collapsed Icon-Only Rail (56pt)

    private var collapsedRailBody: some View {
        VStack(spacing: 0) {
            // Pinned top controls below the hidden titlebar traffic lights
            VStack(spacing: 8) {
                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                        coordinator.isSidebarCollapsed = false
                    }
                } label: {
                    CharkleIcon("sidebar-toggle", style: .duotone, size: 20, isActive: false)
                        .frame(width: 36, height: 34)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("展开侧边栏 (⌘\\)")

                Button {
                    coordinator.isJumpAnywherePresented = true
                } label: {
                    CharkleIcon("search", style: .duotone, size: 19, isActive: false)
                        .frame(width: 36, height: 34)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("快速跳转 (⌘J)")
            }
            .padding(.top, 10)
            .padding(.bottom, 8)

            railDivider

            ScrollView(.vertical) {
                VStack(spacing: 8) {
                railButton(destination: .allItems, icon: "library", tooltip: "全部素材")
                railButton(
                    destination: .inbox,
                    icon: "inbox",
                    tooltip: "收件箱 (\(library.inboxCount))",
                    showDot: library.inboxCount > 0,
                    isDropHighlighted: dropTargetedInbox
                )
                .onDrop(of: [.plainText, .fileURL, .url, .image], isTargeted: $dropTargetedInbox) { providers in
                    handleDrop(providers: providers, folderID: nil, boardID: nil)
                }
                railButton(destination: .untagged, icon: "untagged", tooltip: "未打标签")
                railButton(destination: .recent, icon: "recent", tooltip: "最近添加")
                railButton(destination: .moodboardsHome, icon: "moodboard", tooltip: "所有情绪板")

                if !library.smartFolders.isEmpty {
                    railDivider
                    ForEach(library.smartFolders.prefix(6)) { sf in
                        railButton(
                            destination: .smartFolder(sf.id),
                            icon: "smart-folder",
                            tooltip: "智能文件夹：\(sf.name) (\(library.matchingCount(for: sf)))"
                        )
                    }
                }

                let topFolders = library.childFolders(of: nil)
                if !topFolders.isEmpty {
                    railDivider
                    ForEach(topFolders.prefix(8)) { folder in
                        let isSelected = coordinator.selectedDestination == .folder(folder.id)
                        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                        Button {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                onSelectDestination(.folder(folder.id))
                            }
                        } label: {
                            CharkleFolderIcon(
                                colorHex: folder.colorHex,
                                customSymbol: folder.customSymbol,
                                size: 20,
                                isActive: isSelected
                            )
                            .frame(width: 38, height: 34)
                            .background {
                                if isSelected {
                                    shape
                                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))
                                        .matchedGeometryEffect(id: "sidebar-selection-pill", in: selectionIndicatorNamespace)
                                } else if dropTargetedFolderID == folder.id {
                                    shape
                                        .fill(Color.accentColor.opacity(0.18))
                                        .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
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
                        CharkleIcon("tag", style: .duotone, size: 19, isActive: isAllTagsPopoverPresented)
                            .frame(width: 36, height: 34)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("查看全部标签 (\(library.tagCounts.count))")
                    .popover(isPresented: $isAllTagsPopoverPresented, arrowEdge: .trailing) {
                        allTagsPopoverContent
                    }
                }

                    railButton(destination: .trash, icon: "trash", tooltip: "废纸篓")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .charkleCleanScrollbars(hidden: true)
            }
            .scrollIndicators(.hidden)
            .clipped()

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: 0.75)

            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                    coordinator.openSettings()
                }
            } label: {
                CharkleIcon("settings", style: .duotone, size: 19, isActive: coordinator.isSettingsPresented)
                    .frame(width: 38, height: 34)
                    .background(
                        coordinator.isSettingsPresented
                            ? Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("设置 (⌘,)")
            .padding(.vertical, 8)
        }
    }

    private var railDivider: some View {
        Rectangle()
            .fill(CharkleTheme.hairline(for: colorScheme).opacity(0.85))
            .frame(width: 24, height: 0.75)
            .padding(.vertical, 2)
    }

    private func railButton(
        destination: SidebarDestination,
        icon: String,
        tooltip: String,
        showDot: Bool = false,
        isDropHighlighted: Bool = false
    ) -> some View {
        let isSelected = coordinator.selectedDestination == destination
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                onSelectDestination(destination)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                CharkleIcon(icon, style: .duotone, size: 20, color: isSelected ? Color.accentColor : .secondary, isActive: isSelected)
                    .frame(width: 38, height: 34)
                    .background {
                        if isSelected {
                            shape
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.09))
                                .matchedGeometryEffect(id: "sidebar-selection-pill", in: selectionIndicatorNamespace)
                        } else if isDropHighlighted {
                            shape
                                .fill(Color.accentColor.opacity(0.18))
                                .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
                        }
                    }

                if showDot {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: -5, y: 5)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Expanded Full Sidebar (226pt)

    private var expandedSidebarBody: some View {
        VStack(spacing: 0) {
            // Pinned compact brand header + quick jump + collapse toggle (strictly below traffic lights)
            HStack(spacing: 8) {
                CharkleBrandMark(size: 22)
                Text("Charkle")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                Spacer()
                Button {
                    coordinator.isJumpAnywherePresented = true
                } label: {
                    HStack(spacing: 3) {
                        CharkleIcon("search", style: .duotone, size: 12)
                        Text("⌘J")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("快速跳转 (⌘J)")

                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                        coordinator.isSidebarCollapsed = true
                    }
                } label: {
                    CharkleIcon("sidebar-toggle", style: .duotone, size: 17)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起为仅图标侧边栏 (⌘\\)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: 0.75)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                // Section 1: Library
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("素材库")
                    sidebarRow(
                        destination: .allItems,
                        iconName: "library",
                        title: "全部素材",
                        badgeCount: library.allAssetsByID.values.filter { !$0.isTrashed }.count
                    )
                    sidebarRow(
                        destination: .inbox,
                        iconName: "inbox",
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
                        iconName: "untagged",
                        title: "未打标签",
                        badgeCount: library.allAssetsByID.values.filter { !$0.isTrashed && $0.tags.isEmpty }.count
                    )
                    sidebarRow(
                        destination: .recent,
                        iconName: "recent",
                        title: "最近添加"
                    )
                    sidebarRow(
                        destination: .trash,
                        iconName: "trash",
                        title: "废纸篓"
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
                                    .font(.system(size: 10, weight: .bold))
                                Text("快速生成")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("4 入口 10 秒快速生成情绪板")
                    }
                    .padding(.trailing, 10)

                    sidebarRow(
                        destination: .moodboardsHome,
                        iconName: "moodboard",
                        title: "所有情绪板",
                        badgeCount: moodboards.boards.count
                    )

                    ForEach(moodboards.boards) { board in
                        let isActiveTarget = coordinator.activeMoodboardID == board.id
                        sidebarRow(
                            destination: .moodboard(board.id),
                            iconName: "sparkle-board",
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
                            Button("删除情绪板", role: .destructive) {
                                Task {
                                    await moodboards.deleteBoard(id: board.id)
                                    if coordinator.selectedDestination == .moodboard(board.id) {
                                        onSelectDestination(.moodboardsHome)
                                    }
                                    if coordinator.activeMoodboardID == board.id {
                                        coordinator.activeMoodboardID = moodboards.boards.first?.id
                                    }
                                }
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
                                CharkleIcon("smart-folder", style: .duotone, size: 16)
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
                                iconName: "smart-folder",
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
                            .frame(width: 20)
                            .help("排序文件夹")
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
                        .help("新建文件夹（也可直接从 Finder 拖入文件夹至此）")
                    }
                    .padding(.trailing, 10)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(dropTargetedFolderRoot ? Color.accentColor.opacity(0.14) : Color.clear)
                            .padding(.horizontal, 8)
                    )
                    .onDrop(of: [.plainText, .fileURL, .url], isTargeted: $dropTargetedFolderRoot) { providers in
                        handleFolderHeaderDrop(providers: providers)
                    }

                    if creationTarget == .root {
                        inlineFolderCreatorRow(placeholder: "新文件夹名称", depth: 0)
                    }

                    if library.folders.isEmpty && creationTarget == nil {
                        Text("暂无文件夹，点击 + 或直接拖入外部文件夹")
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
                                folderTreeRow(node)
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

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: 0.75)

            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion)) {
                    coordinator.openSettings()
                }
            } label: {
                HStack(spacing: 8) {
                    CharkleIcon("settings", style: .duotone, size: 17, isActive: coordinator.isSettingsPresented)
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
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        iconName: "tag",
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
                            iconName: "tag",
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
                            iconName: "tag",
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
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                CharkleIcon("search", style: .duotone, size: 15)
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
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { tag in
                        let selected = coordinator.selectedDestination == .tag(tag.name)
                        Button {
                            onSelectDestination(.tag(tag.name))
                            isAllTagsPopoverPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                CharkleIcon("tag", style: .duotone, size: 16, isActive: selected)
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
                                selected ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Rectangle()
                        .fill(Color.accentColor)
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

    private func folderTreeRow(_ node: FolderTreeNode) -> some View {
        let folder = node.folder
        let destination: SidebarDestination = .folder(folder.id)
        let isDestinationSelected = coordinator.selectedDestination == destination
        let isMultiSelected = selectedFolderIDs.contains(folder.id)
        let isSelected = isDestinationSelected || isMultiSelected
        let isDropHighlighted = dropTargetedFolderID == folder.id
        let isHovered = hoveredFolderID == folder.id
        let isPinned = library.isFolderSubtreePinnedOffline(folder.id)
        let rowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let indent = CGFloat(min(node.depth, 5)) * 14

        let targetFolderIDs: [UUID] = {
            if selectedFolderIDs.contains(folder.id) && selectedFolderIDs.count > 1 {
                return visibleFolderTree.map(\.folder.id).filter { selectedFolderIDs.contains($0) }
            }
            return [folder.id]
        }()

        return HStack(spacing: 2) {
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
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.16))
                    .overlay(rowShape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
            } else if isDestinationSelected {
                rowShape
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                    .matchedGeometryEffect(id: "sidebar-selection-pill", in: selectionIndicatorNamespace)
            } else if isDropHighlighted {
                rowShape
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay(rowShape.strokeBorder(Color.accentColor, lineWidth: 1.5))
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
        }
        .onHover { hovering in
            if hovering {
                hoveredFolderID = folder.id
            } else if hoveredFolderID == folder.id {
                hoveredFolderID = nil
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
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
                .controlSize(.small)
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
            if $0.assetCount != $1.assetCount { return $0.assetCount > $1.assetCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for (idx, f) in sorted.enumerated() {
            _ = await library.moveFolder(id: f.id, newParentID: nil, insertAtIndex: idx)
        }
        coordinator.showToast("文件夹已按素材数量排好序", icon: "arrow.up.arrow.down")
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
/// hidden-titlebar scroll pocket hit-testing offset.
public struct CharkleSidebarMaterialBackground: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
    }
}

extension SidebarView {

    private var sidebarSectionDivider: some View {
        Rectangle()
            .fill(CharkleTheme.hairline(for: colorScheme).opacity(0.85))
            .frame(height: 0.75)
            .padding(.horizontal, 14)
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
        iconName: String,
        title: String,
        badgeCount: Int? = nil,
        emphasizeBadge: Bool = false,
        isActiveMoodboard: Bool = false,
        isPinnedOffline: Bool = false,
        isDropHighlighted: Bool = false,
        dotColorHex: String? = nil
    ) -> some View {
        let isSelected = coordinator.selectedDestination == destination
        let rowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                onSelectDestination(destination)
            }
        } label: {
            HStack(spacing: 8) {
                CharkleIcon(
                    iconName,
                    style: .duotone,
                    size: 18,
                    color: isSelected ? Color.accentColor : .secondary,
                    isActive: isSelected
                )

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
                        .fill(Color.green)
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
                        .foregroundStyle(emphasizeBadge ? .white : .secondary)
                        .padding(.horizontal, emphasizeBadge ? 6 : 4)
                        .padding(.vertical, emphasizeBadge ? 2 : 1)
                        .background {
                            if emphasizeBadge {
                                Capsule(style: .continuous).fill(Color.accentColor)
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
                        .matchedGeometryEffect(id: "sidebar-selection-pill", in: selectionIndicatorNamespace)
                } else if isDropHighlighted {
                    rowShape
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(rowShape.strokeBorder(Color.accentColor, lineWidth: 1.5))
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
            var externalInputs: [CaptureInput] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadText(provider),
                   let fids = CharkleDragIdentifiers.decodeFolderIDs(from: str) {
                    draggedFolderIDs.append(contentsOf: fids)
                    continue
                }
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
            } else if !externalInputs.isEmpty {
                let beforeIDs = Set(library.folders.map(\.id))
                let imported = await library.ingest(externalInputs, targetFolderID: nil)
                let newRootFolders = library.folders.filter { !beforeIDs.contains($0.id) && $0.parentID == nil }
                if !newRootFolders.isEmpty {
                    await sortRootFoldersAlphabetically()
                }
                coordinator.showToast("已导入文件夹并整理 \(imported.count) 项素材", icon: "folder.badge.plus")
            }
        }
        return true
    }

    private func handleFolderSlotDrop(providers: [NSItemProvider], parentID: UUID?, insertIndex: Int) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var draggedFolderIDs: [UUID] = []
            var externalInputs: [CaptureInput] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadText(provider),
                   let fids = CharkleDragIdentifiers.decodeFolderIDs(from: str) {
                    draggedFolderIDs.append(contentsOf: fids)
                    continue
                }
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
                coordinator.showToast("已按序导入目录（\(imported.count) 项素材）", icon: "folder.badge.plus")
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
                    else if url.scheme == "http" || url.scheme == "https" {
                        externalInputs.append(.webURL(url, title: nil, notes: nil))
                    }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = await loadData(provider, type: .image) {
                    externalInputs.append(.imageData(data, suggestedName: "SidebarDrop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
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
}

import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Refined translucent macOS Sidebar with Kubai Tip 015 single travelling selection indicator
/// (`matchedGeometryEffect`), live Inbox badge, Moodboards section, hierarchical Folders
/// (nested subfolders, click-outside-to-dismiss creator, drag-drop targets), and Tags.
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

    private struct FolderTreeNode: Identifiable {
        let folder: FolderRecord
        let depth: Int
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

    @State private var dropTargetedFolderID: UUID?
    @State private var dropTargetedInbox: Bool = false
    @State private var dropTargetedBoardID: UUID?

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
            for folder in sortedChildren(of: parentID) where visited.insert(folder.id).inserted {
                let children = byParent[folder.id] ?? []
                let hasChildren = !children.isEmpty
                let isExpanded = expandedFolderIDs.contains(folder.id) || creationTarget == .subfolder(folder.id)
                nodes.append(FolderTreeNode(folder: folder, depth: depth, hasChildren: hasChildren, isExpanded: isExpanded))
                if hasChildren && isExpanded {
                    visit(parentID: folder.id, depth: depth + 1)
                }
            }
        }

        visit(parentID: nil, depth: 0)

        // Safety fallback for any orphaned folder whose parent was not found
        for folder in library.folders where !visited.contains(folder.id) && (folder.parentID == nil || !knownIDs.contains(folder.parentID!)) {
            nodes.append(FolderTreeNode(folder: folder, depth: 0, hasChildren: false, isExpanded: false))
        }
        return nodes
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // Brand compact header
                HStack(spacing: 8) {
                    CharkleIcon("moodboard", style: .layered, size: 22)
                    Text("Charkle")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                    Spacer()
                    Button {
                        coordinator.isJumpAnywherePresented = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10, weight: .semibold))
                            Text("⌘J")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("快速跳转 (⌘J)")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

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

                // Section 3: Hierarchical Folders
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        sectionHeader("文件夹")
                        Spacer()
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
                        .help("新建文件夹")
                    }
                    .padding(.trailing, 10)

                    if creationTarget == .root {
                        inlineFolderCreatorRow(placeholder: "新文件夹名称", depth: 0)
                    }

                    if library.folders.isEmpty && creationTarget == nil {
                        Text("暂无文件夹，点击右上角 + 创建")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(visibleFolderTree) { node in
                            let folder = node.folder
                            if renamingFolderID == folder.id {
                                inlineFolderRenameRow(folder: folder, depth: node.depth)
                            } else {
                                folderTreeRow(node)
                            }

                            if creationTarget == .subfolder(folder.id) {
                                inlineFolderCreatorRow(placeholder: "子文件夹名称", depth: node.depth + 1)
                            }
                        }
                    }
                }

                // Section 4: Tags
                if !library.tagCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("标签")
                        ForEach(library.tagCounts.prefix(18)) { tag in
                            sidebarRow(
                                destination: .tag(tag.name),
                                iconName: "tag",
                                title: "#\(tag.name)",
                                badgeCount: tag.count
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
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
    }

    // MARK: - Folder Tree Row & Inline Creator / Renamer (with Click-Outside Dismiss)

    private func folderTreeRow(_ node: FolderTreeNode) -> some View {
        let folder = node.folder
        let destination: SidebarDestination = .folder(folder.id)
        let isSelected = coordinator.selectedDestination == destination
        let isDropHighlighted = dropTargetedFolderID == folder.id
        let isHovered = hoveredFolderID == folder.id
        let rowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let indent = CGFloat(min(node.depth, 5)) * 14

        return HStack(spacing: 4) {
            if node.hasChildren {
                Button {
                    withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                        if expandedFolderIDs.contains(folder.id) {
                            expandedFolderIDs.remove(folder.id)
                        } else {
                            expandedFolderIDs.insert(folder.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 14)
            }

            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    onSelectDestination(destination)
                }
            } label: {
                HStack(spacing: 7) {
                    CharkleIcon(
                        "folder",
                        style: .duotone,
                        size: 15,
                        color: isSelected ? Color.accentColor : .secondary
                    )
                    Text(folder.name)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered {
                Button {
                    toggleFolderCreation(target: .subfolder(folder.id))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("在「\(folder.name)」内新建子文件夹")
                .transition(.opacity)
            }

            if folder.assetCount > 0 {
                Text("\(folder.assetCount)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            }
        }
        .padding(.leading, 6 + indent)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
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
        .padding(.horizontal, 8)
        .onHover { hovering in
            if hovering {
                hoveredFolderID = folder.id
            } else if hoveredFolderID == folder.id {
                hoveredFolderID = nil
            }
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
        .contextMenu {
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
            Divider()
            Button("删除文件夹（素材退回收件箱）", role: .destructive) {
                Task {
                    await library.deleteFolder(id: folder.id)
                    if coordinator.selectedDestination == .folder(folder.id) {
                        onSelectDestination(.allItems)
                    }
                }
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
        // Avoid instant bounce-reopen when the user clicked the same "+" trigger to dismiss
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
    }

    private func sidebarRow(
        destination: SidebarDestination,
        iconName: String,
        title: String,
        badgeCount: Int? = nil,
        emphasizeBadge: Bool = false,
        isActiveMoodboard: Bool = false,
        isPinnedOffline: Bool = false,
        isDropHighlighted: Bool = false
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
                    size: 15,
                    color: isSelected ? Color.accentColor : .secondary
                )

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))
                    .lineLimit(1)

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
            .padding(.vertical, 6)
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

    private func handleDrop(providers: [NSItemProvider], folderID: UUID?, boardID: UUID?) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var internalIDs: [UUID] = []
            var externalInputs: [CaptureInput] = []

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadText(provider) {
                    if let ids = CharkleDragIdentifiers.decodeAssetIDs(from: str) {
                        internalIDs.append(contentsOf: ids)
                        continue
                    }
                }
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

            if let boardID {
                if !internalIDs.isEmpty { onDropAssetsOntoBoard(internalIDs, boardID) }
                if !externalInputs.isEmpty { onDropExternalOntoBoard(externalInputs, boardID) }
            } else {
                if !internalIDs.isEmpty { onDropAssetsOntoFolder(internalIDs, folderID) }
                if !externalInputs.isEmpty { onDropExternalOntoFolder(externalInputs, folderID) }
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

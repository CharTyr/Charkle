import CharkleCore
import SwiftUI

/// Compact, scalable navigation for iPad `NavigationSplitView` sidebar and iPhone `目录与筛选` drawer:
/// - Pinned top quick-filter search bar for instant jumping across dozens of folders, boards, and tags
/// - Compact 2-column Quick Scope tiles instead of tall vertical boilerplate rows
/// - True collapsible hierarchical folder tree (expanding active ancestor chains automatically,
///   with expand-all/collapse-all toggle and overflow fold so large folder lists never bury other sections)
/// - Horizontal pill cloud for popular tags & collapsible sections for Smart Folders / Moodboards
/// - Pinned bottom Settings & Sync Status dock (always 1 tap away regardless of folder count)
struct SidebarNavigationView: View {
    @Bindable var store: MobileAppStore
    var isCompactSheet: Bool = false
    let onSelectScope: (MobileScope) -> Void
    let onOpenSyncSettings: () -> Void
    let onCreateFolder: () -> Void
    let onCreateMoodboard: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var quickFilter: String = ""
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var showAllRootFolders: Bool = false
    @State private var isFoldersSectionExpanded: Bool = true
    @State private var isSmartFoldersExpanded: Bool = true
    @State private var isMoodboardsExpanded: Bool = true
    @State private var isTagsExpanded: Bool = true
    @State private var folderToDelete: FolderRecord? = nil

    private let collapsedRootLimit = 8

    private var trimmedFilter: String {
        quickFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFiltering: Bool {
        !trimmedFilter.isEmpty
    }

    private var folderTree: [FolderHierarchyNode] {
        store.folderTree
    }

    private var hasNestedFolders: Bool {
        folderTree.contains { $0.hasChildren }
    }

    private var parentFolderIDs: Set<UUID> {
        var ids = Set<UUID>()
        func collect(_ nodes: [FolderHierarchyNode]) {
            for node in nodes where node.hasChildren {
                ids.insert(node.id)
                collect(node.children)
            }
        }
        collect(folderTree)
        return ids
    }

    private var allParentsExpanded: Bool {
        let parents = parentFolderIDs
        return !parents.isEmpty && parents.isSubset(of: expandedFolderIDs)
    }

    private var filteredFolderTree: [FolderHierarchyNode] {
        guard isFiltering else { return folderTree }
        let query = trimmedFilter
        func filterNodes(_ nodes: [FolderHierarchyNode]) -> [FolderHierarchyNode] {
            var result: [FolderHierarchyNode] = []
            for node in nodes {
                let matchedSelf = node.folder.name.localizedCaseInsensitiveContains(query)
                let matchedChildren = filterNodes(node.children)
                if matchedSelf || !matchedChildren.isEmpty {
                    result.append(
                        FolderHierarchyNode(
                            folder: node.folder,
                            depth: node.depth,
                            children: matchedSelf ? node.children : matchedChildren
                        )
                    )
                }
            }
            return result
        }
        return filterNodes(folderTree)
    }

    private var displayedRootFolders: [FolderHierarchyNode] {
        let roots = filteredFolderTree
        if isFiltering || showAllRootFolders || roots.count <= collapsedRootLimit {
            return roots
        }
        var slice = Array(roots.prefix(collapsedRootLimit))
        // Keep the active folder's root branch visible even when collapsed
        if case .folder(let activeID) = store.scope,
           let activeRoot = roots.first(where: { subtreeContains($0, targetID: activeID) }),
           !slice.contains(where: { $0.id == activeRoot.id }) {
            slice[slice.count - 1] = activeRoot
        }
        return slice
    }

    private var hiddenRootFolderCount: Int {
        max(0, filteredFolderTree.count - displayedRootFolders.count)
    }

    private var visibleFolderRows: [FolderHierarchyNode] {
        var rows: [FolderHierarchyNode] = []
        func append(_ nodes: [FolderHierarchyNode]) {
            for node in nodes {
                rows.append(node)
                if node.hasChildren && (isFiltering || expandedFolderIDs.contains(node.id)) {
                    append(node.children)
                }
            }
        }
        append(displayedRootFolders)
        return rows
    }

    private var filteredSmartFolders: [SmartFolderRecord] {
        guard isFiltering else { return store.smartFolders }
        return store.smartFolders.filter { $0.name.localizedCaseInsensitiveContains(trimmedFilter) }
    }

    private var filteredBoards: [MoodboardSummary] {
        guard isFiltering else { return store.boards }
        return store.boards.filter { $0.title.localizedCaseInsensitiveContains(trimmedFilter) }
    }

    private var filteredTags: [TagCount] {
        guard isFiltering else { return store.tagCounts }
        return store.tagCounts.filter { $0.name.localizedCaseInsensitiveContains(trimmedFilter) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Compact Quick Scope Grid (Replaces 6 tall vertical boilerplate rows)
                if !isFiltering {
                    quickScopesPanel
                }

                // 2. Collapsible Hierarchical Folders Tree (Front and center!)
                foldersPanel

                // 3. Collapsible Smart Folders
                if !filteredSmartFolders.isEmpty {
                    smartFoldersPanel
                }

                // 4. Compact Horizontal Tag Cloud (Replaces 12 tall vertical tag rows!)
                if !filteredTags.isEmpty {
                    tagsPanel
                }

                // 5. Collapsible Moodboards (Compact horizontal strip in iPhone sheet, clean list on iPad)
                if !filteredBoards.isEmpty || !isFiltering {
                    moodboardsPanel
                }

                if isFiltering
                    && visibleFolderRows.isEmpty
                    && filteredSmartFolders.isEmpty
                    && filteredTags.isEmpty
                    && filteredBoards.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        Text("没有找到匹配「\(trimmedFilter)」的目录或标签")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .charkleDismissKeyboardOnScroll()
        .background(MobileTheme.sidebarBackground(for: colorScheme))
        .safeAreaInset(edge: .top, spacing: 0) {
            quickFilterHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            pinnedSettingsFooter
        }
        .onAppear {
            expandAncestorsOfActiveScope()
        }
        .onChange(of: store.scope) { _, _ in
            expandAncestorsOfActiveScope()
        }
        .confirmationDialog(
            "删除文件夹「\(folderToDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除文件夹", role: .destructive) {
                if let folder = folderToDelete {
                    folderToDelete = nil
                    Task { await store.deleteFolder(id: folder.id) }
                }
            }
            Button("取消", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("文件夹内的素材不会丢失，将回到全部素材。")
        }
    }

    // MARK: - Pinned Top Quick Filter Bar

    private var quickFilterHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                TextField("快速筛选文件夹、情绪板或标签…", text: $quickFilter)
                    .font(.system(size: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !quickFilter.isEmpty {
                    Button {
                        quickFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(
                MobileTheme.surfaceElevated(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
            )
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)

            Divider().opacity(0.45)
        }
        .background(MobileTheme.sidebarBackground(for: colorScheme))
    }

    // MARK: - Compact 2x2 Quick Scope Tiles + Secondary Pills

    private var quickScopesPanel: some View {
        VStack(spacing: 8) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                scopeTile(
                    scope: .allItems,
                    title: "全部素材",
                    icon: "square.grid.2x2.fill",
                    tint: MobileTheme.accent(for: colorScheme),
                    badge: nil
                )
                scopeTile(
                    scope: .inbox,
                    title: "收件箱",
                    icon: "tray.fill",
                    tint: Color(charkleHex: "#4E7D96"),
                    badge: store.inboxCount > 0 ? store.inboxCount : nil
                )
                scopeTile(
                    scope: .recent,
                    title: "最近 14 天",
                    icon: "clock.fill",
                    tint: Color(charkleHex: "#6B8E76"),
                    badge: nil
                )
                scopeTile(
                    scope: .untagged,
                    title: "未打标",
                    icon: "tag.slash.fill",
                    tint: Color(charkleHex: "#C98212"),
                    badge: nil
                )
            }

            HStack(spacing: 8) {
                compactUtilityPill(
                    scope: .pinterest,
                    title: "Pinterest 空间",
                    icon: "sparkles",
                    tint: Color(charkleHex: "#BA6B55"),
                    badge: store.pinterestController.trayCount > 0 ? store.pinterestController.trayCount : nil
                )
                compactUtilityPill(
                    scope: .trash,
                    title: "回收站",
                    icon: "trash",
                    tint: MobileTheme.secondaryInk(for: colorScheme),
                    badge: nil
                )
            }
        }
    }

    private func scopeTile(
        scope: MobileScope,
        title: String,
        icon: String,
        tint: Color,
        badge: Int?
    ) -> some View {
        let isSelected = store.scope == scope
        return Button {
            MobileHaptics.light()
            onSelectScope(scope)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? tint : tint.opacity(colorScheme == .dark ? 0.20 : 0.13))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : tint)
                }

                Text(title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MobileTheme.accent(for: colorScheme), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                isSelected
                    ? MobileTheme.accentSoft(for: colorScheme)
                    : MobileTheme.surfaceElevated(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? MobileTheme.accent(for: colorScheme).opacity(0.45) : MobileTheme.hairline(for: colorScheme),
                        lineWidth: isSelected ? 1 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(MobileTactileButtonStyle())
    }

    private func compactUtilityPill(
        scope: MobileScope,
        title: String,
        icon: String,
        tint: Color,
        badge: Int?
    ) -> some View {
        let isSelected = store.scope == scope
        return Button {
            MobileHaptics.light()
            onSelectScope(scope)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : tint)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(MobileTheme.accent(for: colorScheme), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                isSelected
                    ? MobileTheme.accentSoft(for: colorScheme)
                    : MobileTheme.surfaceElevated(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
            )
        }
        .buttonStyle(MobileTactileButtonStyle())
    }

    // MARK: - Collapsible Hierarchical Folder Tree

    private var foldersPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: "文件夹",
                count: store.folders.count,
                isExpanded: $isFoldersSectionExpanded
            ) {
                HStack(spacing: 10) {
                    if hasNestedFolders && isFoldersSectionExpanded && !isFiltering {
                        Button {
                            MobileHaptics.light()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                if allParentsExpanded {
                                    expandedFolderIDs.removeAll()
                                } else {
                                    expandedFolderIDs = parentFolderIDs
                                }
                            }
                        } label: {
                            Text(allParentsExpanded ? "收起子目录" : "展开子目录")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        MobileHaptics.light()
                        onCreateFolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新建文件夹")
                }
            }

            if isFoldersSectionExpanded || isFiltering {
                VStack(spacing: 0) {
                    if visibleFolderRows.isEmpty {
                        Text(isFiltering ? "无匹配文件夹" : "尚无文件夹，点右上角新建")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(visibleFolderRows.enumerated()), id: \.element.id) { idx, node in
                            folderRow(node)
                            if idx < visibleFolderRows.count - 1 || hiddenRootFolderCount > 0 || (showAllRootFolders && filteredFolderTree.count > collapsedRootLimit && !isFiltering) {
                                Divider()
                                    .padding(.leading, 38 + CGFloat(min(node.depth, 4)) * 14)
                                    .opacity(0.45)
                            }
                        }

                        if hiddenRootFolderCount > 0 {
                            Button {
                                MobileHaptics.light()
                                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                    showAllRootFolders = true
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.down.circle")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("展开其余 \(hiddenRootFolderCount) 个顶层文件夹")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                }
                                .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else if showAllRootFolders && filteredFolderTree.count > collapsedRootLimit && !isFiltering {
                            Button {
                                MobileHaptics.light()
                                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                    showAllRootFolders = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.up.circle")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("收起多余文件夹")
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer()
                                }
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )
            }
        }
    }

    private func folderRow(_ node: FolderHierarchyNode) -> some View {
        let scope = MobileScope.folder(node.folder.id)
        let isSelected = store.scope == scope
        let isExpanded = isFiltering || expandedFolderIDs.contains(node.id)
        let dotColor = node.folder.colorHex.map { Color(charkleHex: $0) } ?? MobileTheme.accent(for: colorScheme)

        return HStack(spacing: 4) {
            if node.hasChildren {
                Button {
                    MobileHaptics.light()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        if expandedFolderIDs.contains(node.id) {
                            expandedFolderIDs.remove(node.id)
                        } else {
                            expandedFolderIDs.insert(node.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 22, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起子文件夹" : "展开子文件夹")
            } else {
                Spacer().frame(width: 10)
            }

            Button {
                MobileHaptics.light()
                onSelectScope(scope)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: node.hasChildren ? "folder.fill" : "folder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(dotColor)
                        .frame(width: 18)
                    Text(node.folder.name)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if node.hasChildren && !isExpanded {
                        Text("\(node.children.count) 子目录")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                    }
                    if node.folder.assetCount > 0 {
                        Text("\(node.folder.assetCount)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : MobileTheme.tertiaryInk(for: colorScheme))
                    }
                }
                .padding(.vertical, 9)
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4 + CGFloat(min(node.depth, 4)) * 14)
        .background(isSelected ? MobileTheme.accentSoft(for: colorScheme) : .clear)
        .contextMenu {
            if node.hasChildren {
                Button(isExpanded ? "收起子文件夹" : "展开子文件夹", systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        if expandedFolderIDs.contains(node.id) {
                            expandedFolderIDs.remove(node.id)
                        } else {
                            expandedFolderIDs.insert(node.id)
                        }
                    }
                }
            }
            Button("删除文件夹", systemImage: "trash", role: .destructive) {
                folderToDelete = node.folder
            }
        }
    }

    // MARK: - Smart Folders

    private var smartFoldersPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: "智能文件夹",
                count: filteredSmartFolders.count,
                isExpanded: $isSmartFoldersExpanded
            )

            if isSmartFoldersExpanded || isFiltering {
                VStack(spacing: 0) {
                    ForEach(Array(filteredSmartFolders.enumerated()), id: \.element.id) { idx, smart in
                        let scope = MobileScope.smartFolder(smart.id)
                        let isSelected = store.scope == scope
                        Button {
                            MobileHaptics.light()
                            onSelectScope(scope)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(smart.colorHex.map { Color(charkleHex: $0) } ?? MobileTheme.accent(for: colorScheme))
                                    .frame(width: 20)
                                Text(smart.name)
                                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : .primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(isSelected ? MobileTheme.accentSoft(for: colorScheme) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if idx < filteredSmartFolders.count - 1 {
                            Divider().padding(.leading, 40).opacity(0.45)
                        }
                    }
                }
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )
            }
        }
    }

    // MARK: - Compact Horizontal Tag Cloud

    private var tagsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: "热门标签",
                count: filteredTags.count,
                isExpanded: $isTagsExpanded
            )

            if isTagsExpanded || isFiltering {
                let items = Array(filteredTags.prefix(20))
                let rows: [GridItem] = items.count > 6
                    ? [GridItem(.fixed(32), spacing: 7), GridItem(.fixed(32), spacing: 7)]
                    : [GridItem(.fixed(32), spacing: 7)]

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: rows, spacing: 7) {
                        ForEach(items) { item in
                            let scope = MobileScope.tag(item.name)
                            let isSelected = store.scope == scope
                            Button {
                                MobileHaptics.light()
                                onSelectScope(scope)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("#\(item.name)")
                                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                    Text("\(item.count)")
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundStyle(
                                            isSelected ? .white.opacity(0.85) : MobileTheme.tertiaryInk(for: colorScheme)
                                        )
                                }
                                .foregroundStyle(isSelected ? .white : .primary)
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(
                                    isSelected
                                        ? MobileTheme.accentButtonFill(for: colorScheme)
                                        : MobileTheme.surfaceElevated(for: colorScheme),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelected ? .clear : MobileTheme.hairline(for: colorScheme),
                                        lineWidth: 0.75
                                    )
                                )
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Collapsible Moodboards

    private var moodboardsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: "情绪板",
                count: filteredBoards.count,
                isExpanded: $isMoodboardsExpanded
            ) {
                Button {
                    MobileHaptics.light()
                    onCreateMoodboard()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建情绪板")
            }

            if isMoodboardsExpanded || isFiltering {
                if isCompactSheet {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            compactBoardPill(
                                scope: .moodboardsHome,
                                title: "全部情绪板",
                                icon: "rectangle.3.group",
                                count: store.boards.isEmpty ? nil : store.boards.count
                            )
                            ForEach(filteredBoards.prefix(10)) { board in
                                compactBoardPill(
                                    scope: .moodboard(board.id),
                                    title: board.title,
                                    icon: board.mode.isAutoEditorial ? "square.grid.2x2" : "hand.draw",
                                    count: board.itemCount > 0 ? board.itemCount : nil
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    VStack(spacing: 0) {
                        moodboardListRow(
                            scope: .moodboardsHome,
                            title: "全部情绪板",
                            icon: "rectangle.3.group",
                            badge: store.boards.isEmpty ? nil : store.boards.count
                        )
                        ForEach(filteredBoards.prefix(8)) { board in
                            Divider().padding(.leading, 40).opacity(0.45)
                            moodboardListRow(
                                scope: .moodboard(board.id),
                                title: board.title,
                                icon: board.mode.isAutoEditorial ? "square.grid.2x2" : "hand.draw",
                                badge: board.itemCount > 0 ? board.itemCount : nil
                            )
                        }
                    }
                    .background(
                        MobileTheme.surfaceElevated(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                    )
                }
            }
        }
    }

    private func compactBoardPill(scope: MobileScope, title: String, icon: String, count: Int?) -> some View {
        let isSelected = store.scope == scope
        return Button {
            MobileHaptics.light()
            onSelectScope(scope)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? .white : MobileTheme.accent(for: colorScheme))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected ? .white.opacity(0.82) : MobileTheme.tertiaryInk(for: colorScheme))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                isSelected
                    ? MobileTheme.accentButtonFill(for: colorScheme)
                    : MobileTheme.surfaceElevated(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? .clear : MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
            )
        }
        .buttonStyle(MobileTactileButtonStyle())
    }

    private func moodboardListRow(scope: MobileScope, title: String, icon: String, badge: Int?) -> some View {
        let isSelected = store.scope == scope
        return Button {
            MobileHaptics.light()
            onSelectScope(scope)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : MobileTheme.secondaryInk(for: colorScheme))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? MobileTheme.accentSoft(for: colorScheme) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pinned Bottom Settings & Sync Dock (Never Buried by Long Folder Lists)

    private var pinnedSettingsFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.55)
            Button {
                MobileHaptics.light()
                onOpenSyncSettings()
            } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(MobileTheme.surfaceSubtle(for: colorScheme))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                        Circle()
                            .fill(syncIndicatorColor)
                            .frame(width: 9, height: 9)
                            .overlay(
                                Circle().strokeBorder(MobileTheme.sidebarBackground(for: colorScheme), lineWidth: 1.5)
                            )
                            .offset(x: 2, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("设置")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(syncSummarySubtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if store.syncStatus.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(MobileTheme.sidebarBackground(for: colorScheme))
    }

    // MARK: - Reusable Collapsible Section Header

    private func sectionHeader<Trailing: View>(
        title: String,
        count: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                MobileHaptics.light()
                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .rotationEffect(.degrees((isExpanded.wrappedValue || isFiltering) ? 90 : 0))
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            trailing()
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Tree Ancestor Helpers

    private func subtreeContains(_ node: FolderHierarchyNode, targetID: UUID) -> Bool {
        if node.id == targetID { return true }
        return node.children.contains { subtreeContains($0, targetID: targetID) }
    }

    private func expandAncestorsOfActiveScope() {
        guard case .folder(let activeID) = store.scope else { return }
        func findPath(in nodes: [FolderHierarchyNode], target: UUID) -> [UUID]? {
            for node in nodes {
                if node.id == target { return [] }
                if let tail = findPath(in: node.children, target: target) {
                    return [node.id] + tail
                }
            }
            return nil
        }
        if let ancestors = findPath(in: folderTree, target: activeID) {
            expandedFolderIDs.formUnion(ancestors)
        }
    }

    private var syncIndicatorColor: Color {
        if case .error = store.syncStatus.phase {
            return MobileTheme.destructive(for: colorScheme)
        }
        if store.syncStatus.isSyncing {
            return MobileTheme.accent(for: colorScheme)
        }
        return store.hasConnectedCloudBackend
            ? MobileTheme.positive(for: colorScheme)
            : MobileTheme.warning(for: colorScheme)
    }

    private var syncSummarySubtitle: String {
        if store.syncStatus.isSyncing {
            return store.syncStatus.currentDetail ?? store.syncStatus.localizedPhaseTitle
        }
        if let synced = store.syncStatus.lastSyncedAt {
            return "\(store.syncConfig.activeStorageLocationSummary) · \(MobileFormatters.relativeDate(synced))"
        }
        if store.hasConnectedCloudBackend {
            return store.syncConfig.activeStorageLocationSummary
        }
        return "同步、缓存与通用设置"
    }
}

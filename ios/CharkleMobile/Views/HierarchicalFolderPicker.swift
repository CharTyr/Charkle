import CharkleCore
import SwiftUI

// MARK: - Hierarchy Lookup Helpers

extension FolderHierarchyNode {
    /// Returns ancestor folder IDs (from root down to immediate parent, excluding `targetID`)
    /// so pickers can auto-expand only the branch containing the current selection.
    static func ancestorPathIDs(to targetID: UUID, in nodes: [FolderHierarchyNode]) -> [UUID]? {
        for node in nodes {
            if node.folder.id == targetID {
                return []
            }
            if let childPath = ancestorPathIDs(to: targetID, in: node.children) {
                return [node.folder.id] + childPath
            }
        }
        return nil
    }

    /// Returns a readable slash-delimited breadcrumb path (e.g. `"设计 / UI / 图标"`) for `targetID`.
    static func breadcrumbPath(for targetID: UUID, in nodes: [FolderHierarchyNode]) -> String? {
        for node in nodes {
            if node.folder.id == targetID {
                return node.folder.name
            }
            if let suffix = breadcrumbPath(for: targetID, in: node.children) {
                return "\(node.folder.name) / \(suffix)"
            }
        }
        return nil
    }

    func containsFolder(_ targetID: UUID) -> Bool {
        if folder.id == targetID { return true }
        return children.contains { $0.containsFolder(targetID) }
    }
}

// MARK: - Hierarchical Collapsible Folder Picker Sheet

/// Reusable hierarchical folder selector sheet:
/// - Defaults to collapsed top-level folders (auto-expanding only the current folder's ancestor branch)
/// - Supports per-folder chevron expand/collapse, expand-all/collapse-all, and live tree-preserving search
struct HierarchicalFolderPickerSheet: View {
    let title: String
    let folderTree: [FolderHierarchyNode]
    let currentFolderID: UUID?
    let allowInbox: Bool
    let inboxTitle: String
    let onPick: (UUID?, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery: String = ""
    @State private var expandedFolderIDs: Set<UUID> = []

    init(
        title: String = "移动到文件夹",
        folderTree: [FolderHierarchyNode],
        currentFolderID: UUID? = nil,
        allowInbox: Bool = true,
        inboxTitle: String = "收件箱",
        onPick: @escaping (UUID?, String) -> Void
    ) {
        self.title = title
        self.folderTree = folderTree
        self.currentFolderID = currentFolderID
        self.allowInbox = allowInbox
        self.inboxTitle = inboxTitle
        self.onPick = onPick
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearching: Bool {
        !normalizedQuery.isEmpty
    }

    private var totalFolderCount: Int {
        func count(_ nodes: [FolderHierarchyNode]) -> Int {
            nodes.reduce(0) { $0 + 1 + count($1.children) }
        }
        return count(folderTree)
    }

    private var allExpandableIDs: Set<UUID> {
        var ids = Set<UUID>()
        func collect(_ nodes: [FolderHierarchyNode]) {
            for node in nodes where node.hasChildren {
                ids.insert(node.folder.id)
                collect(node.children)
            }
        }
        collect(folderTree)
        return ids
    }

    private var areAllBranchesExpanded: Bool {
        let expandable = allExpandableIDs
        return !expandable.isEmpty && expandable.isSubset(of: expandedFolderIDs)
    }

    private var visibleNodes: [FolderHierarchyNode] {
        let sourceTree = isSearching ? filteredTree(folderTree, query: normalizedQuery) : folderTree
        var output: [FolderHierarchyNode] = []
        func appendVisible(_ nodes: [FolderHierarchyNode]) {
            for node in nodes {
                output.append(node)
                if node.hasChildren && (isSearching || expandedFolderIDs.contains(node.folder.id)) {
                    appendVisible(node.children)
                }
            }
        }
        appendVisible(sourceTree)
        return output
    }

    private var showInboxRow: Bool {
        guard allowInbox else { return false }
        if !isSearching { return true }
        return inboxTitle.lowercased().contains(normalizedQuery) || "inbox".contains(normalizedQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showInboxRow {
                        inboxCard
                    }

                    folderTreeSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .charkleDismissKeyboardOnScroll()
        }
        .background(MobileTheme.galleryGround(for: colorScheme).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .onAppear {
            autoExpandCurrentAncestors()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
            TextField("快速搜索文件夹…", text: $searchQuery)
                .font(.system(size: 14.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
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
            MobileTheme.surfaceSubtle(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var inboxCard: some View {
        let isSelected = currentFolderID == nil
        return Button {
            MobileHaptics.light()
            onPick(nil, inboxTitle)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "tray.fill" : "tray")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    .frame(width: 22)
                Text(inboxTitle)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : .primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isSelected
                    ? MobileTheme.accentSoft(for: colorScheme)
                    : MobileTheme.surfaceElevated(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var folderTreeSection: some View {
        let rows = visibleNodes
        let hasAnyNested = !allExpandableIDs.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("文件夹")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                if totalFolderCount > 0 {
                    Text("\(totalFolderCount)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                }
                Spacer()
                if hasAnyNested && !isSearching {
                    Button {
                        MobileHaptics.light()
                        withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                            if areAllBranchesExpanded {
                                expandedFolderIDs.removeAll()
                            } else {
                                expandedFolderIDs = allExpandableIDs
                            }
                        }
                    } label: {
                        Text(areAllBranchesExpanded ? "全部收起" : "全部展开")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)

            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: isSearching ? "magnifyingglass" : "folder")
                        .font(.system(size: 20))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    Text(isSearching ? "没有匹配的文件夹" : "还没有文件夹")
                        .font(.system(size: 13.5))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, node in
                        folderTreeRow(node)
                        if index < rows.count - 1 {
                            Divider()
                                .padding(.leading, 18 + CGFloat(min(node.depth, 5)) * 16)
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

    private func folderTreeRow(_ node: FolderHierarchyNode) -> some View {
        let isSelected = currentFolderID == node.folder.id
        let isExpanded = isSearching || expandedFolderIDs.contains(node.folder.id)
        let folderColor = node.folder.colorHex.map { Color(charkleHex: $0) } ?? MobileTheme.accent(for: colorScheme)

        return HStack(spacing: 4) {
            if node.depth > 0 {
                Rectangle()
                    .fill(MobileTheme.hairline(for: colorScheme))
                    .frame(width: 1, height: 22)
                    .padding(.trailing, 4)
            }

            if node.hasChildren {
                Button {
                    MobileHaptics.light()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        if expandedFolderIDs.contains(node.folder.id) {
                            expandedFolderIDs.remove(node.folder.id)
                        } else {
                            expandedFolderIDs.insert(node.folder.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 30, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起子文件夹" : "展开子文件夹")
            } else {
                Spacer().frame(width: 14)
            }

            Button {
                MobileHaptics.light()
                onPick(node.folder.id, node.folder.name)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: node.hasChildren ? "folder.fill" : "folder")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(folderColor)
                        .frame(width: 20)
                    Text(node.folder.name)
                        .font(.system(size: 14.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if node.hasChildren && !isExpanded {
                        Text("\(node.children.count) 子目录")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                    }
                    if node.folder.assetCount > 0 {
                        Text("\(node.folder.assetCount)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : MobileTheme.tertiaryInk(for: colorScheme))
                    }
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    }
                }
                .padding(.vertical, 11)
                .padding(.trailing, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4 + CGFloat(min(node.depth, 5)) * 16)
        .background(isSelected ? MobileTheme.accentSoft(for: colorScheme) : .clear)
    }

    private func filteredTree(_ nodes: [FolderHierarchyNode], query: String) -> [FolderHierarchyNode] {
        var result: [FolderHierarchyNode] = []
        for node in nodes {
            let matchingChildren = filteredTree(node.children, query: query)
            if node.folder.name.lowercased().contains(query) || !matchingChildren.isEmpty {
                result.append(
                    FolderHierarchyNode(
                        folder: node.folder,
                        depth: node.depth,
                        children: matchingChildren
                    )
                )
            }
        }
        return result
    }

    private func autoExpandCurrentAncestors() {
        guard let currentFolderID,
              let ancestors = FolderHierarchyNode.ancestorPathIDs(to: currentFolderID, in: folderTree) else {
            return
        }
        expandedFolderIDs.formUnion(ancestors)
    }
}

// MARK: - Cascading Hierarchical Folder Menu Items

/// Recursive `Menu` content that renders only top-level folders at level 1 and nests
/// child folders cleanly inside cascading submenus instead of flattening the entire tree.
struct HierarchicalFolderMenuContent: View {
    let nodes: [FolderHierarchyNode]
    let currentFolderID: UUID?
    let selectSelfPrefix: String
    let onSelect: (UUID, String) -> Void

    init(
        nodes: [FolderHierarchyNode],
        currentFolderID: UUID? = nil,
        selectSelfPrefix: String = "移入",
        onSelect: @escaping (UUID, String) -> Void
    ) {
        self.nodes = nodes
        self.currentFolderID = currentFolderID
        self.selectSelfPrefix = selectSelfPrefix
        self.onSelect = onSelect
    }

    var body: some View {
        ForEach(nodes) { node in
            let isCurrent = currentFolderID == node.folder.id
            if node.hasChildren {
                let containsCurrent = currentFolderID.map { node.containsFolder($0) } ?? false
                Menu {
                    Button {
                        onSelect(node.folder.id, node.folder.name)
                    } label: {
                        Label(
                            "\(selectSelfPrefix)「\(node.folder.name)」" + (isCurrent ? "  ✓" : ""),
                            systemImage: isCurrent ? "folder.fill" : "folder.badge.plus"
                        )
                    }

                    Divider()

                    AnyView(
                        HierarchicalFolderMenuContent(
                            nodes: node.children,
                            currentFolderID: currentFolderID,
                            selectSelfPrefix: selectSelfPrefix,
                            onSelect: onSelect
                        )
                    )
                } label: {
                    Label(
                        node.folder.name + (containsCurrent ? "  •" : ""),
                        systemImage: "folder.fill"
                    )
                }
            } else {
                Button {
                    onSelect(node.folder.id, node.folder.name)
                } label: {
                    Label(
                        node.folder.name + (isCurrent ? "  ✓" : ""),
                        systemImage: isCurrent ? "folder.fill" : "folder"
                    )
                }
            }
        }
    }
}

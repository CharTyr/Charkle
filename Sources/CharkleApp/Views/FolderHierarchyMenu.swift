import AppKit
import CharkleCore
import SwiftUI

/// Recursive native macOS cascading folder submenu content shared across Inspector Quick Actions,
/// Multi-Select Batch Organize, Gallery Context Menus, Floating Action Bar, and Notch Shelf.
///
/// - Folders without children render as direct clickable buttons.
/// - Folders with children render as cascading `Menu` submenus whose first item lets the user
///   target the parent folder itself (`"放入「父目录」"` / `"选择「父目录」"`), followed by a divider
///   and all recursive descendants in deterministic tree order.
public struct CharkleHierarchicalFolderMenuContent: View {
    @Environment(\.colorScheme) private var colorScheme

    public let folders: [FolderRecord]
    public let includeInbox: Bool
    public let selectedFolderID: UUID?
    public let highlightSelection: Bool
    public let parentSelfPrefix: String
    public let onSelectFolder: (UUID?) -> Void

    public init(
        folders: [FolderRecord],
        includeInbox: Bool = true,
        selectedFolderID: UUID? = nil,
        highlightSelection: Bool = false,
        parentSelfPrefix: String = "放入",
        onSelectFolder: @escaping (UUID?) -> Void
    ) {
        self.folders = folders
        self.includeInbox = includeInbox
        self.selectedFolderID = selectedFolderID
        self.highlightSelection = highlightSelection
        self.parentSelfPrefix = parentSelfPrefix
        self.onSelectFolder = onSelectFolder
    }

    public var body: some View {
        let roots = FolderHierarchyNode.buildTree(from: folders)
        let isDark = colorScheme == .dark

        if includeInbox {
            Button {
                onSelectFolder(nil)
            } label: {
                if highlightSelection && selectedFolderID == nil {
                    Label("收件箱", systemImage: "checkmark")
                } else {
                    Label("收件箱", systemImage: "tray")
                }
            }
            if !roots.isEmpty {
                Divider()
            }
        }

        if roots.isEmpty && !includeInbox {
            Text("暂无文件夹")
                .foregroundStyle(.secondary)
        } else {
            FolderHierarchyMenuBranch(
                nodes: roots,
                selectedFolderID: selectedFolderID,
                highlightSelection: highlightSelection,
                parentSelfPrefix: parentSelfPrefix,
                isDark: isDark,
                onSelectFolder: onSelectFolder
            )
        }
    }
}

private struct FolderHierarchyMenuBranch: View {
    let nodes: [FolderHierarchyNode]
    let selectedFolderID: UUID?
    let highlightSelection: Bool
    let parentSelfPrefix: String
    let isDark: Bool
    let onSelectFolder: (UUID?) -> Void

    var body: some View {
        ForEach(nodes) { node in
            let folder = node.folder
            let isSelected = highlightSelection && selectedFolderID == folder.id
            let hasSelectedDescendant = highlightSelection && !isSelected && node.contains(folderID: selectedFolderID)
            let icon = CharkleIconCache.shared.menuFolderIcon(colorHex: folder.colorHex, isDark: isDark)

            if node.hasChildren {
                Menu {
                    Button {
                        onSelectFolder(folder.id)
                    } label: {
                        if isSelected {
                            Label("\(parentSelfPrefix)「\(folder.name)」", systemImage: "checkmark")
                        } else {
                            Label {
                                Text("\(parentSelfPrefix)「\(folder.name)」")
                            } icon: {
                                Image(nsImage: icon)
                            }
                        }
                    }

                    Divider()

                    FolderHierarchyMenuBranch(
                        nodes: node.children,
                        selectedFolderID: selectedFolderID,
                        highlightSelection: highlightSelection,
                        parentSelfPrefix: parentSelfPrefix,
                        isDark: isDark,
                        onSelectFolder: onSelectFolder
                    )
                } label: {
                    Label {
                        Text((isSelected || hasSelectedDescendant) ? "\(folder.name) •" : folder.name)
                    } icon: {
                        Image(nsImage: icon)
                    }
                }
            } else {
                Button {
                    onSelectFolder(folder.id)
                } label: {
                    if isSelected {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Label {
                            Text(folder.name)
                        } icon: {
                            Image(nsImage: icon)
                        }
                    }
                }
            }
        }
    }
}

/// Compact collapsible multi-select hierarchical folder tree (e.g. Moodboard Generator scope selector).
public struct CharkleHierarchicalFolderScopeTree: View {
    @Environment(\.colorScheme) private var colorScheme

    public let folders: [FolderRecord]
    @Binding public var selectedFolderIDs: Set<UUID>
    @State private var expandedIDs: Set<UUID> = []
    @State private var didSeedExpansion: Bool = false

    public init(folders: [FolderRecord], selectedFolderIDs: Binding<Set<UUID>>) {
        self.folders = folders
        self._selectedFolderIDs = selectedFolderIDs
    }

    private var visibleNodes: [FolderHierarchyNode] {
        let roots = FolderHierarchyNode.buildTree(from: folders)
        var result: [FolderHierarchyNode] = []
        func walk(_ nodes: [FolderHierarchyNode]) {
            for node in nodes {
                result.append(node)
                if node.hasChildren && expandedIDs.contains(node.id) {
                    walk(node.children)
                }
            }
        }
        walk(roots)
        return result
    }

    public var body: some View {
        let nodes = visibleNodes
        VStack(alignment: .leading, spacing: 2) {
            // "All Assets" root option
            scopeRow(
                id: nil,
                title: "全部素材（全库检索）",
                depth: 0,
                hasChildren: false,
                colorHex: nil,
                isExpanded: false,
                isSelected: selectedFolderIDs.isEmpty
            ) {
                selectedFolderIDs.removeAll()
            } onToggleExpand: {}

            if !nodes.isEmpty {
                Divider()
                    .opacity(0.45)
                    .padding(.vertical, 2)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(nodes) { node in
                            let folder = node.folder
                            let isSelected = selectedFolderIDs.contains(folder.id)
                            let isExpanded = expandedIDs.contains(folder.id)
                            scopeRow(
                                id: folder.id,
                                title: folder.name,
                                depth: node.depth,
                                hasChildren: node.hasChildren,
                                colorHex: folder.colorHex,
                                isExpanded: isExpanded,
                                isSelected: isSelected
                            ) {
                                if selectedFolderIDs.contains(folder.id) {
                                    selectedFolderIDs.remove(folder.id)
                                } else {
                                    selectedFolderIDs.insert(folder.id)
                                }
                            } onToggleExpand: {
                                if expandedIDs.contains(folder.id) {
                                    expandedIDs.remove(folder.id)
                                } else {
                                    expandedIDs.insert(folder.id)
                                }
                            }
                        }
                    }
                    .charkleCleanScrollbars(hidden: false)
                }
                .frame(maxHeight: 184)
            }
        }
        .padding(6)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
        .onAppear {
            guard !didSeedExpansion else { return }
            didSeedExpansion = true
            // Auto-expand parents of any pre-selected subfolder; if tree is small, expand roots for immediate visibility.
            let roots = FolderHierarchyNode.buildTree(from: folders)
            if folders.count <= 12 {
                for node in FolderHierarchyNode.flattened(from: folders) where node.hasChildren {
                    expandedIDs.insert(node.id)
                }
            } else {
                for root in roots where root.hasChildren {
                    if selectedFolderIDs.contains(where: { root.contains(folderID: $0) }) {
                        expandedIDs.insert(root.id)
                    }
                }
            }
        }
    }

    private func scopeRow(
        id: UUID?,
        title: String,
        depth: Int,
        hasChildren: Bool,
        colorHex: String?,
        isExpanded: Bool,
        isSelected: Bool,
        onTap: @escaping () -> Void,
        onToggleExpand: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 16)
            }

            if hasChildren {
                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if id != nil {
                Spacer().frame(width: 22)
            }

            Button(action: onTap) {
                HStack(spacing: 6) {
                    if id == nil {
                        CharkleIcon("library", style: .duotone, size: 13, color: isSelected ? Color.accentColor : .secondary, isActive: isSelected)
                    } else {
                        CharkleIcon("folder", style: .duotone, size: 13, isActive: isSelected, tintHex: colorHex)
                    }

                    Text(title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.vertical, 4.5)
                .padding(.horizontal, 6)
                .background(
                    isSelected ? Color.accentColor.opacity(0.11) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

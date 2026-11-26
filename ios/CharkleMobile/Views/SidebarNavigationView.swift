import CharkleCore
import SwiftUI

/// Sidebar navigation for iPad `NavigationSplitView` and folder drawer sheet on iPhone.
struct SidebarNavigationView: View {
    @Bindable var store: MobileAppStore
    let onSelectScope: (MobileScope) -> Void
    let onOpenSyncSettings: () -> Void
    let onCreateFolder: () -> Void
    let onCreateMoodboard: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section("素材库") {
                scopeRow(
                    scope: .allItems,
                    title: "全部素材",
                    icon: "square.grid.2x2",
                    badge: nil
                )
                scopeRow(
                    scope: .inbox,
                    title: "收件箱",
                    icon: "tray",
                    badge: store.inboxCount > 0 ? store.inboxCount : nil,
                    emphasizeBadge: true
                )
                scopeRow(
                    scope: .recent,
                    title: "最近 14 天",
                    icon: "clock",
                    badge: nil
                )
                scopeRow(
                    scope: .untagged,
                    title: "未打标",
                    icon: "tag.slash",
                    badge: nil
                )
                scopeRow(
                    scope: .trash,
                    title: "回收站",
                    icon: "trash",
                    badge: nil
                )
            }

            Section {
                scopeRow(
                    scope: .moodboardsHome,
                    title: "全部情绪板",
                    icon: "rectangle.3.group",
                    badge: store.boards.isEmpty ? nil : store.boards.count
                )
                ForEach(store.boards.prefix(8)) { board in
                    scopeRow(
                        scope: .moodboard(board.id),
                        title: board.title,
                        icon: board.mode.isAutoEditorial ? "square.grid.2x2" : "hand.draw",
                        badge: board.itemCount > 0 ? board.itemCount : nil
                    )
                }
            } header: {
                HStack {
                    Text("情绪板")
                    Spacer()
                    Button(action: onCreateMoodboard) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                if store.flattenedFolders.isEmpty {
                    Text("尚无文件夹，点右上角新建")
                        .font(.system(size: 13))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                } else {
                    ForEach(store.flattenedFolders) { node in
                        folderRow(node)
                    }
                }
            } header: {
                HStack {
                    Text("文件夹")
                    Spacer()
                    Button(action: onCreateFolder) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !store.smartFolders.isEmpty {
                Section("智能文件夹") {
                    ForEach(store.smartFolders) { smart in
                        scopeRow(
                            scope: .smartFolder(smart.id),
                            title: smart.name,
                            icon: "line.3.horizontal.decrease.circle",
                            badge: nil,
                            tintHex: smart.colorHex
                        )
                    }
                }
            }

            if !store.tagCounts.isEmpty {
                Section("热门标签") {
                    ForEach(store.tagCounts.prefix(12)) { item in
                        scopeRow(
                            scope: .tag(item.name),
                            title: "#\(item.name)",
                            icon: "number",
                            badge: item.count
                        )
                    }
                }
            }

            Section("云端同步") {
                syncStatusCard
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(MobileTheme.sidebarBackground(for: colorScheme))
    }

    private func scopeRow(
        scope: MobileScope,
        title: String,
        icon: String,
        badge: Int?,
        emphasizeBadge: Bool = false,
        tintHex: String? = nil
    ) -> some View {
        let isSelected = store.scope == scope
        return Button {
            MobileHaptics.light()
            onSelectScope(scope)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? MobileTheme.accent(for: colorScheme)
                            : (tintHex.map { Color(charkleHex: $0) } ?? MobileTheme.secondaryInk(for: colorScheme))
                    )
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(emphasizeBadge ? .white : MobileTheme.secondaryInk(for: colorScheme))
                        .padding(.horizontal, emphasizeBadge ? 7 : 0)
                        .padding(.vertical, emphasizeBadge ? 2 : 0)
                        .background(
                            emphasizeBadge ? MobileTheme.accent(for: colorScheme) : .clear,
                            in: Capsule()
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                .fill(isSelected ? MobileTheme.accentSoft(for: colorScheme) : .clear)
        )
    }

    private func folderRow(_ node: FolderHierarchyNode) -> some View {
        let scope = MobileScope.folder(node.folder.id)
        let isSelected = store.scope == scope
        let dotColor = node.folder.colorHex.map { Color(charkleHex: $0) } ?? MobileTheme.accent(for: colorScheme)

        return Button {
            MobileHaptics.light()
            onSelectScope(scope)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: node.hasChildren ? "folder.fill" : "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(dotColor)
                    .frame(width: 20)
                Text(node.folder.name)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if node.folder.assetCount > 0 {
                    Text("\(node.folder.assetCount)")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
            }
            .padding(.leading, CGFloat(min(node.depth, 4)) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                .fill(isSelected ? MobileTheme.accentSoft(for: colorScheme) : .clear)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await store.deleteFolder(id: node.folder.id) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var syncStatusCard: some View {
        Button(action: onOpenSyncSettings) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(syncIndicatorColor)
                        .frame(width: 8, height: 8)
                    Text(store.hasConnectedCloudBackend ? store.syncConfig.activeStorageLocationSummary : "未连接云盘")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if store.syncStatus.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                }
                Text(syncSummarySubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .lineLimit(2)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            return "上次同步 · \(MobileFormatters.relativeDate(synced))"
        }
        if let account = store.syncStatus.account {
            return account.email
        }
        return "支持 iCloud / Google Drive / WebDAV 多后端同步"
    }
}

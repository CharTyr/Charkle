import CharkleCore
import SwiftUI

enum MobileSettingsRoute: Hashable, Sendable {
    case sync
}

/// Unified iOS / iPadOS Settings hub:
/// - Cloud Sync (`同步设置`) lives cleanly as a first-class sub-page (`GoogleDriveSyncSettingsView`)
/// - Local cache budget & eviction live under Storage (`存储与离线缓存`)
/// - Quick capture tips & About info stay clean and focused (no desktop-only clutter)
struct MobileSettingsView: View {
    @Bindable var store: MobileAppStore
    let showDoneButton: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var cacheBudgetGB: Double = 4.0

    private var appVersionSummary: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "13"
        return "v\(short) (\(build))"
    }

    private var syncStatusColor: Color {
        if case .error = store.syncStatus.phase {
            return MobileTheme.destructive(for: colorScheme)
        }
        if store.isSyncing || store.syncStatus.isSyncing {
            return MobileTheme.accent(for: colorScheme)
        }
        return store.hasConnectedCloudBackend
            ? MobileTheme.positive(for: colorScheme)
            : MobileTheme.warning(for: colorScheme)
    }

    private var syncSummarySubtitle: String {
        if store.isSyncing || store.syncStatus.isSyncing {
            return store.syncStatus.currentDetail ?? store.syncStatus.localizedPhaseTitle
        }
        if let err = store.syncStatus.lastError, !err.isEmpty {
            return "同步异常：\(err)"
        }
        let enabledCount = store.syncConfig.enabledBackends.count
        if let syncedAt = store.syncStatus.lastSyncedAt {
            let pending = store.syncStatus.pendingOpCount
            if pending > 0 {
                return "\(store.syncConfig.activeStorageLocationSummary) · \(pending) 条待上传"
            }
            if enabledCount > 1 {
                return "已启用 \(enabledCount) 个后端 · \(MobileFormatters.relativeDate(syncedAt))"
            }
            return "\(store.syncConfig.activeStorageLocationSummary) · \(MobileFormatters.relativeDate(syncedAt))"
        }
        if store.hasConnectedCloudBackend {
            return enabledCount > 1
                ? "已启用 \(enabledCount) 个并行同步后端"
                : store.syncConfig.activeStorageLocationSummary
        }
        return "未连接云盘 · 点击配置 iCloud / Google Drive / WebDAV"
    }

    var body: some View {
        Form {
            // 1. Cloud Sync Sub-Item + Quick Action
            Section {
                NavigationLink(value: MobileSettingsRoute.sync) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(syncStatusColor.opacity(colorScheme == .dark ? 0.22 : 0.14))
                                .frame(width: 32, height: 32)
                            Image(systemName: store.hasConnectedCloudBackend ? "icloud.fill" : "icloud")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(syncStatusColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("同步设置")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(syncSummarySubtitle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(
                                    store.syncStatus.lastError != nil
                                        ? MobileTheme.destructive(for: colorScheme)
                                        : MobileTheme.secondaryInk(for: colorScheme)
                                )
                                .lineLimit(2)
                        }

                        Spacer(minLength: 4)

                        if store.isSyncing || store.syncStatus.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Circle()
                                .fill(syncStatusColor)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .padding(.vertical, 3)
                }

                if store.syncConfig.enabledBackends.count > 0 {
                    if store.syncStatus.isSyncing, let fraction = store.syncStatus.progressFraction {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: max(0, min(1, fraction)))
                                .tint(MobileTheme.accent(for: colorScheme))
                            Text(store.syncStatus.currentDetail ?? store.syncStatus.localizedPhaseTitle)
                                .font(.system(size: 12))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    } else {
                        Button {
                            MobileHaptics.light()
                            Task { await store.syncNow(quiet: false) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(
                                    (store.isSyncing || store.syncStatus.isSyncing)
                                        ? "正在双向同步…"
                                        : "立即双向同步"
                                )
                                .font(.system(size: 14.5, weight: .medium))
                            }
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                        }
                        .disabled(store.isSyncing || store.syncStatus.isSyncing)
                    }
                }
            } header: {
                Text("云端同步")
            } footer: {
                Text("管理 iCloud Drive、Google Drive、WebDAV 与本地目录的多后端并行同步与授权凭据。")
            }

            // 2. Gallery Layout & Version Stack Preferences
            Section {
                Picker(
                    "默认画廊视图",
                    selection: Binding(
                        get: { store.defaultGalleryLayoutMode },
                        set: { store.setDefaultGalleryLayoutMode($0) }
                    )
                ) {
                    Label("纵向瀑布流", systemImage: "square.grid.2x2")
                        .tag(GalleryLayoutMode.verticalMasonry)
                    Label("紧凑视图", systemImage: "list.bullet")
                        .tag(GalleryLayoutMode.compactList)
                }

                if !store.scopeLayoutOverrides.isEmpty {
                    HStack {
                        Text("已记忆独立视图的目录")
                        Spacer()
                        Text("\(store.scopeLayoutOverrides.count) 个位置")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Button("重置各文件夹的独立视图记忆") {
                        store.resetPerFolderLayoutMemory()
                    }
                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
            } header: {
                Text("画廊视图与文档版本叠")
            } footer: {
                Text("切换文件夹视图时会自动按目录单独记忆（例如摄影目录用瀑布流、办公文档目录用紧凑视图）；分享版本叠时默认锁定对外「主版本」，防止误发未审草稿。")
            }

            // 3. Local Storage & Offline Cache
            Section {
                metricRow("缩略图缓存", MobileFormatters.byteCount(store.cacheStats.thumbnailBytes))
                metricRow(
                    "已缓存原图（\(store.cacheStats.cachedOriginalCount) 项）",
                    MobileFormatters.byteCount(store.cacheStats.originalCacheBytes)
                )
                metricRow(
                    "离线置顶原图（\(store.cacheStats.pinnedAssetCount) 项）",
                    MobileFormatters.byteCount(store.cacheStats.pinnedOfflineBytes)
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("原图缓存上限")
                        Spacer()
                        Text("\(String(format: "%.1f", cacheBudgetGB)) GB")
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $cacheBudgetGB, in: 1...16, step: 0.5) { editing in
                        if !editing {
                            Task { await store.updateCacheBudget(gigabytes: cacheBudgetGB) }
                        }
                    }
                    .tint(MobileTheme.accent(for: colorScheme))
                }

                Button("清理可回收缓存") {
                    MobileHaptics.light()
                    Task { await store.evictCacheNow() }
                }
            } header: {
                Text("存储与离线缓存")
            } footer: {
                Text("缩略图常驻本机实现瞬开翻找，高清原图按需拉取并自动按上限回收；已置顶离线原图永不自动清理。")
            }

            // 3. Quick Capture Tips
            Section("采集与快捷使用") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("支持系统「分享面板」随手收藏", systemImage: "square.and.arrow.up.on.square")
                        .font(.system(size: 14, weight: .semibold))
                    Text("在小红书、X、Safari 或系统相册中点击「分享 → 存到 Charkle」，打开应用后自动完成解析入库并同步到已连接的全部云端后端。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .padding(.vertical, 3)

                if store.assets.isEmpty {
                    Button("载入精选示例素材库") {
                        Task { await store.seedSampleLibrary() }
                    }
                }
            }

            // 4. About Charkle
            Section("关于") {
                metricRow("版本", appVersionSummary)
                metricRow("文件夹 / 情绪板", "\(store.folders.count) 个文件夹 · \(store.boards.count) 个情绪板")
            }
        }
        .charkleScrollEdgeSoft(for: .bottom)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(showDoneButton ? .inline : .large)
        .navigationDestination(for: MobileSettingsRoute.self) { route in
            switch route {
            case .sync:
                GoogleDriveSyncSettingsView(
                    store: store,
                    showDoneButton: false,
                    includeStorageAndTips: false
                )
            }
        }
        .toolbar {
            if showDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            cacheBudgetGB = max(1.0, min(16.0, Double(store.cacheStats.budgetBytes) / 1_073_741_824.0))
            Task { await store.loadSyncAndStorageState() }
        }
        .onChange(of: store.cacheStats.budgetBytes) { _, bytes in
            cacheBudgetGB = max(1.0, min(16.0, Double(bytes) / 1_073_741_824.0))
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(size: 13.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

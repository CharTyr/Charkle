import AppKit
import CharkleCore
import SwiftUI

/// Tab 2: 素材库 (Library) — Current storage location, guided lossless migration/switch wizard,
/// and two-tier local disk cache management.
public struct LibrarySettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore

    @State private var cacheBudgetGB: Double = 10.0
    @State private var didSyncInitialBudget: Bool = false

    @State private var showLocationWizard: Bool = false
    @State private var wizardAction: LocationWizardAction = .migrate
    @State private var draftTargetConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var migrationWebDAVPassword: String = ""

    private enum LocationWizardAction: String, CaseIterable {
        case migrate
        case switchOnly

        var label: String {
            switch self {
            case .migrate: "完整无损迁移（推荐）"
            case .switchOnly: "仅切换指向位置"
            }
        }
    }

    public init(coordinator: AppCoordinatorStore, syncAndAI: SyncAndAIStore) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        let cfg = syncAndAI.syncConfig
        let stats = syncAndAI.cacheStats
        let totalUsed = stats.thumbnailBytes + stats.originalCacheBytes + stats.pinnedOfflineBytes
        let barScale = max(Int64(1), max(totalUsed, stats.budgetBytes))

        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("当前存储位置") {
                SettingsRow(
                    title: storageHeadline(for: cfg),
                    subtitle: cfg.activeStorageLocationSummary,
                    subtitleColor: cfg.mode == .localOnly ? .secondary : SettingsPalette.positiveInk(for: colorScheme)
                ) {
                    HStack(spacing: 8) {
                        if cfg.mode == .localOnly {
                            Button("在访达中打开") {
                                let url = URL(
                                    fileURLWithPath: (cfg.localLibraryPath as NSString).expandingTildeInPath,
                                    isDirectory: true
                                )
                                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        } else {
                            Button("同步设置") {
                                coordinator.selectedSettingsTab = .sync
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }

                        Button("更改或转移…") {
                            syncAndAI.errorMessage = nil
                            syncAndAI.statusMessage = nil
                            draftTargetConfig = syncAndAI.syncConfig
                            if draftTargetConfig.mode == .gdirectMount {
                                draftTargetConfig.mode = .directAPIWithGDirect
                            }
                            wizardAction = .migrate
                            migrationWebDAVPassword = ""
                            showLocationWizard = true
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)
                    }
                }

                if cfg.mode == .localOnly {
                    SettingsCardDivider()

                    SettingsRow(
                        title: "本机目录同步检查",
                        subtitle: "手动扫描当前本机文件夹内新增的文件并补齐索引"
                    ) {
                        Button {
                            Task { _ = await syncAndAI.syncNow() }
                        } label: {
                            HStack(spacing: 5) {
                                if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                                Text("立即扫描")
                            }
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)
                    }
                }

                InlineGuideDisclosure("切换存储方式会丢失素材吗？怎么安全搬家") {
                    SettingsGuideStep(
                        "1",
                        title: "选择「完整无损迁移（推荐）」不会丢失任何内容",
                        detail: "Charkle 会先验证新位置可写、自动拉取尚未缓存在本机的云端原件，再把全部文件夹、原图与情绪板写入新位置。"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "「仅切换指向位置」适合接入已有素材库",
                        detail: "如果你在另一台 Mac 或云盘已有现成的 Charkle 目录，仅切换指向即可直接连接，不搬运本机现有文件。"
                    )
                    SettingsGuideStep(
                        "3",
                        title: "随时可在 Google Drive、WebDAV 与纯本地之间互迁",
                        detail: "原始文件均按可读文件夹保存，不锁定专有格式，在访达或网盘网页端都能直接查看。"
                    )
                }
            }

            SettingsSection("本机缓存空间") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("已使用本机缓存")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: totalUsed, countStyle: .file)) / \(Int(cacheBudgetGB.rounded())) GB 上限")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        let w = max(10, geo.size.width)
                        let thumbW = stats.thumbnailBytes > 0 ? max(8, w * CGFloat(Double(stats.thumbnailBytes) / Double(barScale))) : 0
                        let origW = stats.originalCacheBytes > 0 ? max(8, w * CGFloat(Double(stats.originalCacheBytes) / Double(barScale))) : 0
                        let pinW = stats.pinnedOfflineBytes > 0 ? max(8, w * CGFloat(Double(stats.pinnedOfflineBytes) / Double(barScale))) : 0
                        HStack(spacing: 2) {
                            if thumbW > 0 {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(charkleHex: "#4E7D96"))
                                    .frame(width: min(w * 0.45, thumbW))
                            }
                            if origW > 0 {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(charkleHex: "#D4A373"))
                                    .frame(width: min(w * 0.45, origW))
                            }
                            if pinW > 0 {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(charkleHex: "#6B8E76"))
                                    .frame(width: min(w * 0.45, pinW))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(3)
                        .background(
                            SettingsPalette.subtleFill(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .frame(height: 18)

                    HStack(spacing: 20) {
                        legendItem(color: Color(charkleHex: "#4E7D96"), title: "画廊预览图", bytes: stats.thumbnailBytes)
                        legendItem(color: Color(charkleHex: "#D4A373"), title: "临时原件（\(stats.cachedOriginalCount) 项）", bytes: stats.originalCacheBytes)
                        legendItem(color: Color(charkleHex: "#6B8E76"), title: "常驻离线（\(stats.pinnedAssetCount) 项）", bytes: stats.pinnedOfflineBytes)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("临时原件缓存上限")
                                .font(.system(size: 13, weight: .medium))
                            Text("超出上限时按最久未用自动回收，常驻离线素材与预览图不受影响")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(cacheBudgetGB.rounded())) GB")
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    Slider(value: $cacheBudgetGB, in: 2...100, step: 1) { editing in
                        if !editing {
                            Task { await syncAndAI.setCacheBudgetGB(cacheBudgetGB) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                SettingsCardDivider()

                SettingsRow(
                    title: "清理临时原件缓存",
                    subtitle: "立即释放未设为「始终保留在本地」的临时原件，云端与本地原件安全保留"
                ) {
                    Button("立即清理") {
                        Task { await syncAndAI.evictCacheNow() }
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                    .disabled(syncAndAI.isBusy)
                }
            }
        }
        .onAppear {
            syncBudgetFromStoreIfNeeded()
        }
        .onChange(of: syncAndAI.cacheStats.budgetBytes) { _, _ in
            syncBudgetFromStoreIfNeeded(force: true)
        }
        .sheet(isPresented: $showLocationWizard) {
            storageLocationWizardSheet
        }
    }

    private func syncBudgetFromStoreIfNeeded(force: Bool = false) {
        guard force || !didSyncInitialBudget else { return }
        let gb = Double(syncAndAI.cacheStats.budgetBytes) / (1024 * 1024 * 1024)
        if gb > 0 {
            cacheBudgetGB = max(2, min(100, gb))
            didSyncInitialBudget = true
        }
    }

    private func storageHeadline(for config: DriveSyncConfig) -> String {
        switch config.mode {
        case .localOnly: "纯本地文件夹"
        case .directAPIWithGDirect: "Google Drive 云端直连"
        case .gdirectMount: "Google Drive（gdirect 本地挂载）"
        case .webDAV: "WebDAV 云盘"
        }
    }

    private func legendItem(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Unified Location Migration / Switch Wizard Sheet

    private var storageLocationWizardSheet: some View {
        let targetModeBinding = Binding<DriveTransportMode>(
            get: { draftTargetConfig.mode == .gdirectMount ? .directAPIWithGDirect : draftTargetConfig.mode },
            set: { draftTargetConfig.mode = $0 }
        )

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("更改或转移素材库位置")
                        .font(.system(size: 15, weight: .semibold))
                    Text("当前位置：\(syncAndAI.syncConfig.activeStorageLocationSummary)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            SettingsSheetFeedbackBanner(syncAndAI: syncAndAI)

            VStack(alignment: .leading, spacing: 6) {
                Text("操作方式")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $wizardAction) {
                    ForEach(LocationWizardAction.allCases, id: \.self) { action in
                        Text(action.label).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("目标存储方式")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: targetModeBinding) {
                    Text("Google Drive").tag(DriveTransportMode.directAPIWithGDirect)
                    Text("WebDAV 云盘").tag(DriveTransportMode.webDAV)
                    Text("纯本地文件夹").tag(DriveTransportMode.localOnly)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 10) {
                switch draftTargetConfig.mode {
                case .directAPIWithGDirect, .gdirectMount:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标 Google Drive 路径")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("Charkle 或 Design/Charkle", text: $draftTargetConfig.rootFolderName)
                            .textFieldStyle(.roundedBorder)
                    }
                    let hasReadyGoogleAccount = (syncAndAI.syncStatus.account != nil
                        && syncAndAI.syncStatus.account?.source != "WebDAV"
                        && syncAndAI.syncStatus.account?.source != "本地文件夹")
                        || syncAndAI.gdirectSnapshot.defaultAccount != nil
                        || !syncAndAI.gdirectSnapshot.accounts.isEmpty
                    if !hasReadyGoogleAccount {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.orange)
                            Text("迁移到 Google Drive 前请先在「云同步」完成账号登录。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("前往云同步") {
                                showLocationWizard = false
                                coordinator.selectedSettingsTab = .sync
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }
                    }

                case .webDAV:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("服务器地址（如 https://dav.jianguoyun.com/dav/）", text: $draftTargetConfig.webDAVServerURL)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            TextField("用户名", text: $draftTargetConfig.webDAVUsername)
                                .textFieldStyle(.roundedBorder)
                            SecureField(syncAndAI.hasWebDAVPassword ? "应用密码（留空沿用已存）" : "应用密码", text: $migrationWebDAVPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("远端保存路径（如 /Charkle）", text: $draftTargetConfig.webDAVRemotePath)
                            .textFieldStyle(.roundedBorder)
                    }

                case .localOnly:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目标本机文件夹路径")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("~/Pictures/Charkle", text: $draftTargetConfig.localLibraryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("选择文件夹…") {
                                if let picked = SettingsHelpers.pickLocalDirectory(initialPath: draftTargetConfig.localLibraryPath) {
                                    draftTargetConfig.localLibraryPath = picked
                                }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(wizardAction == .migrate ? "无损迁移流程" : "仅切换说明")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(
                    wizardAction == .migrate
                        ? "1. 验证目标位置连通与可写性，避免中断损坏原库；\n2. 自动补全拉取尚未缓存在本机的云端原件；\n3. 将全部文件夹、素材原件与情绪板完整写入新位置并切换为默认存储。"
                        : "仅将 Charkle 指向新位置并保存配置，不搬运原位置的现有文件；适合接入已有云端或本地素材库。"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SettingsPalette.subtleFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

            HStack {
                Button("取消") {
                    showLocationWizard = false
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(syncAndAI.isMigrating)

                Spacer()

                Button {
                    let target = draftTargetConfig
                    let pwd = migrationWebDAVPassword
                    Task {
                        if wizardAction == .migrate {
                            if await syncAndAI.migrateLibraryStorage(
                                to: target,
                                webDAVPassword: pwd.isEmpty ? nil : pwd
                            ) != nil {
                                showLocationWizard = false
                            }
                        } else {
                            if target.mode == .webDAV, !pwd.isEmpty {
                                _ = await syncAndAI.saveWebDAVPassword(pwd)
                            }
                            await syncAndAI.saveSyncConfig(target, quiet: false)
                            showLocationWizard = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if syncAndAI.isMigrating {
                            ProgressView().controlSize(.mini)
                        }
                        Text(
                            wizardAction == .migrate
                                ? (syncAndAI.isMigrating ? "正在迁移素材库…" : "开始无损迁移")
                                : "切换至该位置"
                        )
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(syncAndAI.isBusy || !canConfirmTarget)
            }
        }
        .padding(22)
        .frame(width: 530)
    }

    private var canConfirmTarget: Bool {
        switch draftTargetConfig.mode {
        case .localOnly:
            return !draftTargetConfig.localLibraryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .webDAV:
            return !draftTargetConfig.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .directAPIWithGDirect, .gdirectMount:
            return !draftTargetConfig.rootFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

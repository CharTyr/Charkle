import CharkleCore
import SwiftUI

/// Tab 3: 云同步 (Sync) — Status-first cloud account & sync controls for Google Drive and WebDAV,
/// team shared folder collaboration, and sync preferences. Low-level `gdirect` internals live in Tab 9.
public struct SyncSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore

    @State private var draftConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var didLoadDraft: Bool = false

    @State private var showOAuthSetupSheet: Bool = false
    @State private var showWebDAVConfigSheet: Bool = false
    @State private var webDAVDraftURL: String = ""
    @State private var webDAVDraftUsername: String = ""
    @State private var webDAVDraftRemotePath: String = "/Charkle"
    @State private var webDAVPasswordInput: String = ""
    @State private var editingBackend: SyncBackendProfile? = nil
    @State private var isCreatingNewBackend: Bool = false
    @State private var backendWebDAVPasswordDraft: String = ""
    @FocusState private var isRootFolderFieldFocused: Bool
    @FocusState private var isSharedFolderFieldFocused: Bool

    public init(coordinator: AppCoordinatorStore, syncAndAI: SyncAndAIStore) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
    }

    private var hasGoogleBackend: Bool {
        draftConfig.resolvedBackends.contains { $0.mode == .directAPIWithGDirect || $0.mode == .gdirectMount }
    }

    private var hasICloudBackend: Bool {
        draftConfig.resolvedBackends.contains { $0.mode == .iCloudDrive }
    }

    private var hasWebDAVBackend: Bool {
        draftConfig.resolvedBackends.contains { $0.mode == .webDAV }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if draftConfig.enabledCloudBackends.isEmpty && draftConfig.resolvedBackends.count <= 1 && draftConfig.mode == .localOnly {
                localOnboardingSection
            } else {
                liveSyncStatusSection
                connectedBackendsSection

                if hasGoogleBackend {
                    googleDriveAccountSection
                    googleSharedCollaborationSection
                }
                if hasICloudBackend {
                    iCloudDriveInfoSection
                }
                if hasWebDAVBackend && draftConfig.resolvedBackends.count == 1 {
                    webDAVAccountSection
                }

                syncPreferencesSection
            }
        }
        .onAppear {
            draftConfig = syncAndAI.syncConfig
            didLoadDraft = true
        }
        .onChange(of: syncAndAI.syncConfig) { _, latest in
            var merged = latest
            if isRootFolderFieldFocused {
                merged.rootFolderName = draftConfig.rootFolderName
            }
            if isSharedFolderFieldFocused {
                merged.sharedFolderURLOrID = draftConfig.sharedFolderURLOrID
            }
            draftConfig = merged
        }
        .sheet(isPresented: $showOAuthSetupSheet) {
            GoogleOAuthSetupSheet(syncAndAI: syncAndAI, autoSignInAfterSave: true)
        }
        .sheet(isPresented: $showWebDAVConfigSheet) {
            webDAVEditorSheet
        }
        .sheet(item: $editingBackend) { profile in
            backendProfileEditorSheet(initial: profile)
        }
    }

    // MARK: - State A: Local-Only Guidance

    private var localOnboardingSection: some View {
        SettingsSection("云端同步服务") {
            SettingsRow(
                title: "当前素材库仅保存在本机",
                subtitle: "路径：\(draftConfig.localLibraryPath) · 启用云同步可在多台 Mac 间自动同步并支持团队共享"
            ) {
                Button("管理素材库位置") {
                    coordinator.selectedSettingsTab = .library
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .fixedSize()
            }

            SettingsCardDivider()

            SettingsRow(
                title: "Google Drive 云端直连",
                subtitle: "推荐 · 原始文件按可读目录保存在你的 Google Drive，支持共享协作与网页端直接拖入新素材"
            ) {
                Button("启用 Google 同步") {
                    draftConfig.mode = .directAPIWithGDirect
                    persistIfReady()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .fixedSize()
            }

            InlineGuideDisclosure("开始前需要准备什么？（仅首次需 3 分钟配置凭据）") {
                SettingsGuideStep(
                    "1",
                    title: "直连你自己的 Google Drive，不经任何第三方中转服务器",
                    detail: "因此首次登录前需要准备一份个人桌面端 OAuth 凭据（client_secret.json）。"
                )
                SettingsGuideStep(
                    "2",
                    title: "如果你本机已装过 gdirect，可直接一键导入",
                    detail: "启用 Google 同步后，Charkle 会自动检测本机 gdirect 并提供免填导入。"
                )
                SettingsGuideStep(
                    "3",
                    title: "想把已有本地素材一并迁上云盘？",
                    detail: "请前往「素材库 → 更改或转移…」选择完整无损迁移，自动搬运原件与情绪板。"
                )
            }

            SettingsCardDivider()

            SettingsRow(
                title: "iCloud Drive 云同步",
                subtitle: "免配置 OAuth · 直接通过苹果 iCloud Drive 与 iPhone / iPad / 多台 Mac 自动双向同步"
            ) {
                Button("启用 iCloud Drive") {
                    draftConfig.mode = .iCloudDrive
                    draftConfig.backends = [
                        SyncBackendProfile(
                            id: SyncBackendProfile.legacyPrimaryID,
                            name: "iCloud Drive",
                            mode: .iCloudDrive,
                            isEnabled: true,
                            isPrimary: true,
                            iCloudFolderName: draftConfig.iCloudFolderName
                        )
                    ]
                    draftConfig.synchronizePrimaryFields()
                    persistIfReady()
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .fixedSize()
            }

            SettingsCardDivider()

            SettingsRow(
                title: "WebDAV 云盘",
                subtitle: "兼容坚果云、Nextcloud、群晖 NAS、Alist 等任意标准 WebDAV 服务"
            ) {
                Button("配置 WebDAV…") {
                    openWebDAVEditor()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .fixedSize()
            }
        }
    }

    // MARK: - Multi-Backend Simultaneous Connections Section

    private var connectedBackendsSection: some View {
        let profiles = draftConfig.resolvedBackends
        let statusByID = Dictionary(uniqueKeysWithValues: syncAndAI.syncStatus.backendStatuses.map { ($0.backendID, $0) })

        return SettingsSection("已连接的同步后端（支持同时连接多个）") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { idx, profile in
                    if idx > 0 {
                        SettingsCardDivider()
                    }
                    backendRow(profile: profile, status: statusByID[profile.id], totalCount: profiles.count)
                }

                SettingsCardDivider()

                HStack(spacing: 10) {
                    Menu {
                        Button("iCloud Drive", systemImage: "icloud") {
                            openNewBackendSheet(mode: .iCloudDrive)
                        }
                        Button("Google Drive", systemImage: "externaldrive.badge.icloud") {
                            openNewBackendSheet(mode: .directAPIWithGDirect)
                        }
                        Button("WebDAV 云盘", systemImage: "server.rack") {
                            openNewBackendSheet(mode: .webDAV)
                        }
                        Button("本地镜像文件夹", systemImage: "folder") {
                            openNewBackendSheet(mode: .localOnly)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(CharkleTheme.accent(for: colorScheme, source: coordinator.accentSource))
                            Text("添加同步后端…")
                                .font(CharkleTheme.text(.body, weight: .semibold))
                            CharkleDropdownChevron(size: 8.5)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Spacer()

                    Text("同时启用多个后端时，所有素材、文件夹与情绪板将自动双向镜像到每个后端。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func backendRow(profile: SyncBackendProfile, status: SyncBackendStatus?, totalCount: Int) -> some View {
        let isBusy = syncAndAI.isBusy || (status?.isSyncing == true)
        let dotColor: Color = {
            if !profile.isEnabled { return .secondary.opacity(0.45) }
            if let status {
                if case .error = status.phase { return SettingsPalette.destructiveInk(for: colorScheme) }
                if status.isSyncing { return SettingsPalette.warningInk(for: colorScheme) }
                if status.lastSyncedAt != nil { return SettingsPalette.positiveInk(for: colorScheme) }
            }
            return .secondary
        }()
        let subtitle: String = {
            if !profile.isEnabled { return "已暂停 · \(profile.locationSummary)" }
            if let err = status?.lastError, !err.isEmpty { return "异常：\(err)" }
            if let syncedAt = status?.lastSyncedAt {
                return "\(profile.locationSummary) · 上次同步 \(SettingsHelpers.relativeTimeText(syncedAt))"
            }
            return profile.locationSummary
        }()

        return HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                    .fill(SettingsPalette.subtleFill(for: colorScheme))
                    .frame(width: 34, height: 34)
                Image(systemName: backendSymbol(for: profile.mode))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(profile.isEnabled ? .primary : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    Text(profile.name)
                        .font(CharkleTheme.text(.body, weight: .semibold))
                    if profile.isPrimary {
                        SettingsStatusBadge("主后端", tint: SettingsPalette.positiveInk(for: colorScheme))
                    } else {
                        SettingsStatusBadge("并行镜像", tint: .secondary)
                    }
                }
                Text(subtitle)
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(status?.lastError != nil ? SettingsPalette.destructiveInk(for: colorScheme) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { profile.isEnabled },
                set: { enabled in
                    Task { await syncAndAI.setBackendEnabled(id: profile.id, enabled: enabled) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button("编辑") {
                isCreatingNewBackend = false
                backendWebDAVPasswordDraft = ""
                editingBackend = profile
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .fixedSize()

            Menu {
                Button("立即同步此后端", systemImage: "arrow.triangle.2.circlepath") {
                    Task { _ = await syncAndAI.syncBackend(id: profile.id) }
                }
                .disabled(!profile.isEnabled || isBusy)

                if !profile.isPrimary {
                    Button("设为主后端", systemImage: "star") {
                        Task { await syncAndAI.setPrimaryBackend(id: profile.id) }
                    }
                }

                if totalCount > 1 {
                    Divider()
                    Button("移除此后端", systemImage: "trash", role: .destructive) {
                        Task { await syncAndAI.removeBackend(id: profile.id) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(CharkleMenuTriggerButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var iCloudDriveInfoSection: some View {
        let avail = syncAndAI.iCloudAvailability
        return SettingsSection("iCloud Drive 状态") {
            SettingsRow(
                title: avail.hasAutomaticPath ? "本机 iCloud Drive 已就绪" : "请确认系统已开启 iCloud Drive",
                subtitle: avail.systemCloudDocsPath.map { "目录：\($0) · 与 iPhone / iPad「文件 → iCloud Drive」完全互通" }
                    ?? (avail.ubiquityDocumentsPath ?? "请在系统设置 → Apple ID → iCloud 中开启 iCloud 云盘，或在后端编辑中手动指定目录")
            ) {
                if let primaryICloud = draftConfig.resolvedBackends.first(where: { $0.mode == .iCloudDrive }) {
                    Button("测试 iCloud") {
                        Task { _ = await syncAndAI.testBackendConnection(primaryICloud) }
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                    .disabled(syncAndAI.isBusy)
                }
            }
        }
    }

    private func backendProfileEditorSheet(initial: SyncBackendProfile) -> some View {
        DesktopBackendEditorSheetView(
            initial: initial,
            isNew: isCreatingNewBackend,
            syncAndAI: syncAndAI,
            onDismiss: { editingBackend = nil }
        )
    }

    private func openNewBackendSheet(mode: DriveTransportMode) {
        isCreatingNewBackend = true
        backendWebDAVPasswordDraft = ""
        let count = draftConfig.resolvedBackends.filter { $0.mode == mode }.count
        let defaultName = count == 0 ? mode.localizedLabel : "\(mode.localizedLabel) \(count + 1)"
        editingBackend = SyncBackendProfile(
            name: defaultName,
            mode: mode,
            isEnabled: true,
            isPrimary: false
        )
    }

    private func backendSymbol(for mode: DriveTransportMode) -> String {
        switch mode {
        case .iCloudDrive: "icloud"
        case .directAPIWithGDirect: "externaldrive.badge.icloud"
        case .gdirectMount: "externaldrive.connected.to.line.below"
        case .webDAV: "server.rack"
        case .localOnly: "folder"
        }
    }

    // MARK: - Live Sync Progress Section

    private var liveSyncStatusSection: some View {
        let status = syncAndAI.syncStatus
        let isSyncing = status.isSyncing || syncAndAI.isBusy
        let percentText = status.progressFraction.map { "\(Int(($0 * 100).rounded()))%" }

        return SettingsSection("同步状态") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(syncIndicatorColor(status))
                            .frame(width: 8, height: 8)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(isSyncing ? status.localizedPhaseTitle : syncIdleHeadline(status))
                                .font(CharkleTheme.text(.body, weight: .medium))
                            if isSyncing, let percentText {
                                Text(percentText)
                                    .font(CharkleTheme.text(.caption, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(syncSubheadline(status: status, isSyncing: isSyncing))
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(status.lastError != nil && !isSyncing ? SettingsPalette.destructiveInk(for: colorScheme) : .secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 10)

                    Button {
                        let snapshot = draftConfig
                        Task {
                            if snapshot != syncAndAI.syncConfig {
                                await syncAndAI.saveSyncConfig(snapshot, quiet: true)
                            }
                            _ = await syncAndAI.syncNow()
                        }
                    } label: {
                        Text(isSyncing ? "同步中…" : "立即同步")
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                    .disabled(isSyncing)
                }

                if isSyncing {
                    if let fraction = status.progressFraction {
                        ProgressView(value: min(1.0, max(0.0, fraction)))
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }

                HStack(spacing: 12) {
                    Label(
                        status.lastSyncedAt.map { "上次同步：\(SettingsHelpers.relativeTimeText($0))" } ?? "尚未完成首次同步",
                        systemImage: "clock"
                    )
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)

                    if status.pendingOpCount > 0 {
                        Label("待上传 \(status.pendingOpCount) 项", systemImage: "arrow.up.circle")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(SettingsPalette.warningInk(for: colorScheme))
                            .monospacedDigit()
                    }

                    Spacer()

                    if let report = syncAndAI.lastSyncReport {
                        Text("↑ \(report.uploadedOps)  ↓ \(report.downloadedOps)  +\(report.discoveredRemoteAssets) 新发现")
                            .font(CharkleTheme.text(.caption, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Google Drive Account Section

    private var googleDriveAccountSection: some View {
        let snap = syncAndAI.gdirectSnapshot
        let isMountMode = draftConfig.mode == .gdirectMount
        let gdirectEmail = draftConfig.selectedGDirectAccount ?? snap.defaultAccount ?? snap.accounts.first
        let directAccount: DriveAccountInfo? = {
            guard let acc = syncAndAI.syncStatus.account,
                  acc.source != "WebDAV",
                  acc.source != "本地文件夹",
                  acc.source != "gdirect",
                  acc.source != "gdirect mount" else { return nil }
            return acc
        }()
        let activeAccount: DriveAccountInfo? = {
            if isMountMode {
                return gdirectEmail.map { DriveAccountInfo(email: $0, displayName: nil, source: "gdirect mount") }
            }
            return directAccount
                ?? gdirectEmail.map { DriveAccountInfo(email: $0, displayName: nil, source: "gdirect") }
        }()
        let isUsingGDirectFallback = !isMountMode && directAccount == nil && activeAccount != nil

        return SettingsSection("Google Drive 账号") {
            if isMountMode {
                SettingsRow(
                    title: gdirectEmail ?? "当前处于 gdirect 本地挂载模式",
                    subtitle: snap.isMountActive
                        ? "已挂载至 \(draftConfig.mountPath)（如需切回免挂载高速直连，可前往「高级与关于」管理）"
                        : "当前挂载卷未激活，可在「高级与关于」执行挂载或切回标准直连 API",
                    subtitleColor: snap.isMountActive
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : SettingsPalette.warningInk(for: colorScheme)
                ) {
                    HStack(spacing: 8) {
                        Button("切回标准直连") {
                            draftConfig.mode = .directAPIWithGDirect
                            persistIfReady()
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()

                        Button("挂载管理") {
                            coordinator.selectedSettingsTab = .advancedAbout
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(SettingsPalette.subtleFill(for: colorScheme))
                                .frame(width: 38, height: 38)
                            Image(systemName: activeAccount != nil ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(activeAccount != nil ? SettingsPalette.positiveInk(for: colorScheme) : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(activeAccount?.displayName ?? activeAccount?.email ?? "未登录 Google 账号")
                                    .font(CharkleTheme.text(.body, weight: .semibold))
                                if directAccount != nil {
                                    SettingsStatusBadge("已直连", tint: SettingsPalette.positiveInk(for: colorScheme))
                                } else if isUsingGDirectFallback {
                                    SettingsStatusBadge("gdirect 兜底", tint: SettingsPalette.warningInk(for: colorScheme))
                                }
                            }

                            if let account = activeAccount, let name = account.displayName, !name.isEmpty {
                                Text(account.email)
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(googleAccountHint(hasOAuth: syncAndAI.hasGoogleOAuthClient, hasGDirect: snap.cliPath != nil, isFallback: isUsingGDirectFallback))
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer(minLength: 8)

                        if directAccount != nil {
                            HStack(spacing: 8) {
                                Button("切换账号") {
                                    triggerGoogleSignIn()
                                }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                                .fixedSize()
                                .disabled(syncAndAI.isBusy)

                                Button("退出") {
                                    Task { await syncAndAI.signOutGoogleDrive() }
                                }
                                .buttonStyle(SettingsDestructiveButtonStyle())
                                .fixedSize()
                                .disabled(syncAndAI.isBusy)
                            }
                        } else if !syncAndAI.hasGoogleOAuthClient && snap.cliPath != nil {
                            HStack(spacing: 8) {
                                Button("从 gdirect 导入并登录") {
                                    Task {
                                        if await syncAndAI.importGoogleOAuthFromGDirect() {
                                            _ = await syncAndAI.signInGoogleDrive()
                                        }
                                    }
                                }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                                .fixedSize()
                                .disabled(syncAndAI.isBusy)

                                Button("手动配置…") {
                                    showOAuthSetupSheet = true
                                }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                                .fixedSize()
                            }
                        } else {
                            Button(syncAndAI.hasGoogleOAuthClient ? "使用 Google 登录" : "配置凭据并登录") {
                                triggerGoogleSignIn()
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                            .disabled(syncAndAI.isBusy)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    if let used = activeAccount?.storageUsedBytes,
                       let limit = activeAccount?.storageLimitBytes, limit > 0 {
                        let ratio = min(1.0, max(0.0, Double(used) / Double(limit)))
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Google Drive 云端空间")
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: ratio)
                                .progressViewStyle(.linear)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 11)
                    }

                    if !syncAndAI.hasGoogleOAuthClient && directAccount == nil {
                        InlineGuideDisclosure("为什么首次登录需要配置一次凭据？") {
                            SettingsGuideStep(
                                "1",
                                title: "你的素材直连个人 Google Drive，零中转",
                                detail: "Charkle 不经过云端代理服务器，所有原图和情绪板直接读写你自己的网盘。"
                            )
                            SettingsGuideStep(
                                "2",
                                title: "按教程 3 分钟创建一次桌面端 Client ID 即可长期使用",
                                detail: "点击「配置凭据并登录」即可打开官方教程链接，支持直接导入下载的 client_secret.json。"
                            )
                        }
                    }
                }
            }

            SettingsCardDivider()

            SettingsRow(
                title: "云端保存路径",
                subtitle: draftConfig.resolvedSharedFolderID != nil
                    ? "当前已绑定下方共享协作目录；清除后将恢复使用此路径"
                    : "支持单级目录（Charkle）或多级路径（Design/Charkle）"
            ) {
                TextField("Charkle", text: $draftConfig.rootFolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .disabled(draftConfig.resolvedSharedFolderID != nil)
                    .focused($isRootFolderFieldFocused)
                    .onSubmit {
                        let path = draftConfig.rootFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                        persistIfReady(message: path.isEmpty ? "已更新云端保存路径" : "云端保存路径已更新为「\(path)」")
                    }
                    .onChange(of: isRootFolderFieldFocused) { wasFocused, nowFocused in
                        if wasFocused && !nowFocused {
                            let path = draftConfig.rootFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                            persistIfReady(message: path.isEmpty ? "已更新云端保存路径" : "云端保存路径已更新为「\(path)」")
                        }
                    }
            }
        }
    }

    // MARK: - Google Drive Shared Collaboration

    private var googleSharedCollaborationSection: some View {
        let isSignedIn = syncAndAI.syncStatus.account != nil
            && syncAndAI.syncStatus.account?.source != "WebDAV"
            && syncAndAI.syncStatus.account?.source != "本地文件夹"
            && syncAndAI.syncStatus.account?.source != "gdirect"
            && syncAndAI.syncStatus.account?.source != "gdirect mount"
        let trimmed = draftConfig.sharedFolderURLOrID.trimmingCharacters(in: .whitespacesAndNewlines)

        return SettingsSection("团队共享协作（可选）") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("共享协作目录")
                            .font(CharkleTheme.text(.body, weight: .medium))
                        if let sharedID = draftConfig.resolvedSharedFolderID {
                            Text("已启用协作模式（目录 ID：\(String(sharedID.prefix(12)))…）")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(SettingsPalette.positiveInk(for: colorScheme))
                        } else if !trimmed.isEmpty {
                            Text("链接或 ID 格式无效，请检查是否包含 /folders/…")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(SettingsPalette.warningInk(for: colorScheme))
                        } else {
                            Text("粘贴 Google Drive「与我共享」目录链接或 ID，多人可共同整理与浏览")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if isSignedIn {
                        Menu {
                            if syncAndAI.sharedFolders.isEmpty {
                                Button("加载「与我共享」目录列表…") {
                                    Task { await syncAndAI.loadSharedFolders() }
                                }
                            } else {
                                ForEach(syncAndAI.sharedFolders, id: \.id) { folder in
                                    Button {
                                        draftConfig.sharedFolderURLOrID = folder.webViewLink ?? folder.id
                                        persistIfReady(message: "已绑定共享协作目录「\(folder.name)」")
                                    } label: {
                                        Label(folder.name, systemImage: "folder.badge.person.crop")
                                    }
                                }
                                Divider()
                                Button("刷新列表") {
                                    Task { await syncAndAI.loadSharedFolders() }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if syncAndAI.isLoadingSharedFolders {
                                    ProgressView().controlSize(.mini)
                                }
                                Text("选择与我共享")
                                    .font(CharkleTheme.text(.body, weight: .medium))
                                CharkleDropdownChevron(size: 8.5)
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .task(id: isSignedIn) {
                            if isSignedIn && syncAndAI.sharedFolders.isEmpty && !syncAndAI.isLoadingSharedFolders {
                                await syncAndAI.loadSharedFolders()
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("https://drive.google.com/drive/folders/… 或目录 ID", text: $draftConfig.sharedFolderURLOrID)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSharedFolderFieldFocused)
                        .onSubmit {
                            let val = draftConfig.sharedFolderURLOrID.trimmingCharacters(in: .whitespacesAndNewlines)
                            persistIfReady(message: val.isEmpty ? "已清除团队共享协作目录" : "已更新团队共享协作目录")
                        }
                        .onChange(of: isSharedFolderFieldFocused) { wasFocused, nowFocused in
                            if wasFocused && !nowFocused {
                                let val = draftConfig.sharedFolderURLOrID.trimmingCharacters(in: .whitespacesAndNewlines)
                                persistIfReady(message: val.isEmpty ? "已清除团队共享协作目录" : "已更新团队共享协作目录")
                            }
                        }

                    if !trimmed.isEmpty {
                        Button("清除") {
                            draftConfig.sharedFolderURLOrID = ""
                            persistIfReady(message: "已清除团队共享协作目录")
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            InlineGuideDisclosure("如何与团队成员共享同一个素材库") {
                SettingsGuideStep(
                    "1",
                    title: "在 Google Drive 网页端将 Charkle 文件夹共享给协作者（编辑者权限）"
                )
                SettingsGuideStep(
                    "2",
                    title: "协作者登录 Charkle 后，点击上方「选择与我共享」或直接粘贴目录链接",
                    detail: "所有成员对标签、文件夹与情绪板的编辑都会通过增量日志安全合并，互不覆盖。"
                )
            }
        }
    }

    // MARK: - WebDAV Account Section

    private var webDAVAccountSection: some View {
        let isConnected = syncAndAI.syncStatus.account?.source == "WebDAV"
        let host = URL(string: draftConfig.webDAVServerURL)?.host() ?? draftConfig.webDAVServerURL

        return SettingsSection("WebDAV 服务") {
            SettingsRow(
                title: host.isEmpty ? "尚未配置 WebDAV 服务器" : host,
                subtitle: host.isEmpty
                    ? "支持坚果云、Nextcloud、群晖 NAS、Alist 等标准 WebDAV 服务"
                    : "账号：\(draftConfig.webDAVUsername.isEmpty ? "未填写" : draftConfig.webDAVUsername) · 路径：\(draftConfig.webDAVRemotePath)",
                subtitleColor: isConnected ? SettingsPalette.positiveInk(for: colorScheme) : .secondary
            ) {
                HStack(spacing: 8) {
                    Button("测试连接") {
                        let cfg = draftConfig
                        Task { _ = await syncAndAI.testWebDAVConnection(config: cfg, password: nil) }
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                    .disabled(draftConfig.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncAndAI.isBusy)

                    Button("编辑配置…") {
                        openWebDAVEditor()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }
            }

            InlineGuideDisclosure("坚果云 / 群晖 NAS 如何获取应用密码") {
                SettingsGuideStep(
                    "1",
                    title: "坚果云用户请使用「第三方应用管理」生成的专用密码",
                    detail: "服务器地址一般为 https://dav.jianguoyun.com/dav/，不要直接使用网页登录密码。"
                )
                SettingsGuideStep(
                    "2",
                    title: "密码仅加密保存于 macOS 钥匙串",
                    detail: "不会明文写入任何配置文件。"
                )
            }
        }
    }

    // MARK: - Sync Preferences

    private var syncPreferencesSection: some View {
        SettingsSection("同步偏好") {
            SettingsRow(
                title: "同步轻量化预览图",
                subtitle: "切换其他 Mac 时秒看完整画廊，无需等待下载原始大文件"
            ) {
                Toggle("", isOn: $draftConfig.syncThumbnails)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: draftConfig.syncThumbnails) { _, newVal in
                        persistIfReady(message: newVal ? "已开启同步轻量化预览图" : "已关闭同步轻量化预览图")
                    }
            }

            SettingsCardDivider()

            SettingsRow(
                title: "同步智能搜索索引",
                subtitle: "在多台设备间共享搜索索引，保持一致的搜图与情绪板推荐体验"
            ) {
                Toggle("", isOn: $draftConfig.syncEmbeddings)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: draftConfig.syncEmbeddings) { _, newVal in
                        persistIfReady(message: newVal ? "已开启同步智能搜索索引" : "已关闭同步智能搜索索引")
                    }
            }
        }
    }

    // MARK: - WebDAV Editor Sheet

    private var webDAVEditorSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("配置 WebDAV 云盘")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("兼容坚果云、Nextcloud、群晖 NAS、Alist 等任意标准 WebDAV 服务")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            SettingsSheetFeedbackBanner(syncAndAI: syncAndAI)

            VStack(alignment: .leading, spacing: 10) {
                fieldRow("服务器地址") {
                    TextField("https://dav.jianguoyun.com/dav/", text: $webDAVDraftURL)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("账号 / 用户名") {
                    TextField("邮箱或用户名", text: $webDAVDraftUsername)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("应用密码（保存至 macOS 钥匙串）") {
                    SecureField(syncAndAI.hasWebDAVPassword ? "••••••••（留空保持不变）" : "输入密码或应用授权码", text: $webDAVPasswordInput)
                        .textFieldStyle(.roundedBorder)
                }
                fieldRow("云端保存路径") {
                    TextField("/Charkle", text: $webDAVDraftRemotePath)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("取消") {
                    showWebDAVConfigSheet = false
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("测试连接") {
                    var testCfg = draftConfig
                    testCfg.mode = .webDAV
                    testCfg.webDAVServerURL = webDAVDraftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    testCfg.webDAVUsername = webDAVDraftUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    testCfg.webDAVRemotePath = webDAVDraftRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    let pwd = webDAVPasswordInput
                    Task {
                        let ok = await syncAndAI.testWebDAVConnection(config: testCfg, password: pwd.isEmpty ? nil : pwd)
                        if ok {
                            draftConfig = syncAndAI.syncConfig
                            webDAVPasswordInput = ""
                        }
                    }
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(webDAVDraftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncAndAI.isBusy)

                Button("保存配置") {
                    var updated = draftConfig
                    updated.mode = .webDAV
                    updated.webDAVServerURL = webDAVDraftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.webDAVUsername = webDAVDraftUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.webDAVRemotePath = webDAVDraftRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    let pwd = webDAVPasswordInput
                    Task {
                        if !pwd.isEmpty {
                            _ = await syncAndAI.saveWebDAVPassword(pwd)
                            webDAVPasswordInput = ""
                        }
                        await syncAndAI.saveSyncConfig(updated, quiet: false)
                        draftConfig = syncAndAI.syncConfig
                        showWebDAVConfigSheet = false
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(webDAVDraftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncAndAI.isBusy)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func fieldRow<F: View>(_ label: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            field()
        }
    }

    // MARK: - Helpers

    private func openWebDAVEditor() {
        syncAndAI.errorMessage = nil
        syncAndAI.statusMessage = nil
        webDAVDraftURL = draftConfig.webDAVServerURL
        webDAVDraftUsername = draftConfig.webDAVUsername
        webDAVDraftRemotePath = draftConfig.webDAVRemotePath.isEmpty ? "/Charkle" : draftConfig.webDAVRemotePath
        webDAVPasswordInput = ""
        showWebDAVConfigSheet = true
    }

    private func triggerGoogleSignIn() {
        Task {
            if syncAndAI.hasGoogleOAuthClient {
                _ = await syncAndAI.signInGoogleDrive()
            } else {
                showOAuthSetupSheet = true
            }
        }
    }

    private func persistIfReady(message: String? = nil) {
        guard didLoadDraft else { return }
        let snapshot = draftConfig
        guard snapshot != syncAndAI.syncConfig else { return }
        Task {
            await syncAndAI.saveSyncConfig(
                snapshot,
                quiet: message == nil,
                successMessage: message
            )
        }
    }

    private func googleAccountHint(hasOAuth: Bool, hasGDirect: Bool, isFallback: Bool) -> String {
        if isFallback {
            return "当前暂用本机 gdirect 兜底，独立登录 Google 账号后可启用免挂载 HTTP/2 高速直连"
        }
        if !hasOAuth {
            return hasGDirect
                ? "检测到本机 gdirect，可一键导入凭据并完成登录"
                : "首次登录需配置一次 Google 桌面端凭据，完成后自动开启直连同步"
        }
        return "登录 Google 账号后，素材与情绪板将自动直连同步"
    }

    private func syncIndicatorColor(_ status: SyncStatus) -> Color {
        switch status.phase {
        case .error: return SettingsPalette.destructiveInk(for: colorScheme)
        case .scanning, .uploading, .downloading, .merging: return SettingsPalette.warningInk(for: colorScheme)
        case .idle:
            if status.pendingOpCount > 0 { return SettingsPalette.warningInk(for: colorScheme) }
            return status.lastSyncedAt != nil ? SettingsPalette.positiveInk(for: colorScheme) : .secondary
        }
    }

    private func syncIdleHeadline(_ status: SyncStatus) -> String {
        if case .error = status.phase { return "上次同步遇到异常" }
        if status.pendingOpCount > 0 { return "有 \(status.pendingOpCount) 项本地变更待同步" }
        return status.lastSyncedAt != nil ? "已与云端保持同步" : "等待首次同步"
    }

    private func syncSubheadline(status: SyncStatus, isSyncing: Bool) -> String {
        if isSyncing {
            if let detail = status.currentDetail, !detail.isEmpty { return detail }
            return "正在与 \(draftConfig.activeStorageLocationSummary) 同步…"
        }
        if let err = status.lastError, !err.isEmpty { return err }
        return "目标：\(draftConfig.activeStorageLocationSummary)"
    }
}

private struct DesktopBackendEditorSheetView: View {
    let isNew: Bool
    let syncAndAI: SyncAndAIStore
    let onDismiss: () -> Void

    @State private var draft: SyncBackendProfile
    @State private var webDAVPassword: String = ""

    init(initial: SyncBackendProfile, isNew: Bool, syncAndAI: SyncAndAIStore, onDismiss: @escaping () -> Void) {
        self._draft = State(initialValue: initial)
        self.isNew = isNew
        self.syncAndAI = syncAndAI
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: draft.mode == .iCloudDrive ? "icloud" : "externaldrive.connected.to.line.below")
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "添加同步后端" : "编辑同步后端")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("所有已启用的后端会在同步时并行镜像文件夹、原图、缩略图与情绪板")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            SettingsSheetFeedbackBanner(syncAndAI: syncAndAI)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("后端名称")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("例如：iCloud Drive / 家庭 NAS", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                if isNew {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("后端类型")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $draft.mode) {
                            Text("iCloud Drive").tag(DriveTransportMode.iCloudDrive)
                            Text("Google Drive").tag(DriveTransportMode.directAPIWithGDirect)
                            Text("WebDAV").tag(DriveTransportMode.webDAV)
                            Text("本地目录").tag(DriveTransportMode.localOnly)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                switch draft.mode {
                case .iCloudDrive:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("iCloud Drive 文件夹名（自动映射至 iCloud Drive / 目录名）")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("Charkle", text: $draft.iCloudFolderName)
                            .textFieldStyle(.roundedBorder)

                        Text("或指定自定义 iCloud Drive 文件夹路径（可选）")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("留空自动使用系统 iCloud Drive / \(draft.iCloudFolderName.isEmpty ? "Charkle" : draft.iCloudFolderName)", text: $draft.iCloudCustomFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("选择…") {
                                let initial = draft.iCloudCustomFolderPath.isEmpty
                                    ? (ICloudDriveTransport.macOSCloudDocsURL()?.path ?? NSHomeDirectory())
                                    : draft.iCloudCustomFolderPath
                                if let picked = SettingsHelpers.pickLocalDirectory(initialPath: initial) {
                                    draft.iCloudCustomFolderPath = picked
                                }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }
                    }

                case .directAPIWithGDirect, .gdirectMount:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Google Drive 目录路径")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("Charkle 或 Design/Charkle", text: $draft.rootFolderName)
                            .textFieldStyle(.roundedBorder)
                        Text("共享目录链接 / ID（可选）")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("https://drive.google.com/drive/folders/…", text: $draft.sharedFolderURLOrID)
                            .textFieldStyle(.roundedBorder)
                    }

                case .webDAV:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("服务器地址（https://dav.jianguoyun.com/dav/）", text: $draft.webDAVServerURL)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            TextField("用户名", text: $draft.webDAVUsername)
                                .textFieldStyle(.roundedBorder)
                            SecureField("密码（留空保持不变）", text: $webDAVPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("远端路径（/Charkle）", text: $draft.webDAVRemotePath)
                            .textFieldStyle(.roundedBorder)
                    }

                case .localOnly:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("本地镜像文件夹路径")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("~/Pictures/Charkle", text: $draft.localLibraryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("选择…") {
                                if let picked = SettingsHelpers.pickLocalDirectory(initialPath: draft.localLibraryPath) {
                                    draft.localLibraryPath = picked
                                }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }
                    }
                }
            }

            HStack {
                Button("取消", action: onDismiss)
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("测试连接") {
                    let candidate = draft
                    let pwd = webDAVPassword
                    Task {
                        _ = await syncAndAI.testBackendConnection(candidate, webDAVPassword: pwd.isEmpty ? nil : pwd)
                    }
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(syncAndAI.isBusy)

                Button(isNew ? "添加并保存" : "保存修改") {
                    var finalProfile = draft
                    if finalProfile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finalProfile.name = finalProfile.mode.localizedLabel
                    }
                    let pwd = webDAVPassword
                    Task {
                        if await syncAndAI.upsertBackend(finalProfile, webDAVPassword: pwd.isEmpty ? nil : pwd) {
                            onDismiss()
                        }
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(syncAndAI.isBusy)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

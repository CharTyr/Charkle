import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Product-grade macOS Settings window designed around user intent:
/// Multi-backend storage & sync (Google Drive via gdirect OAuth, WebDAV, Pure Local Folder)
/// with configurable library paths and lossless two-way storage migration,
/// multi-format Custom AI endpoints (OpenAI Chat Completions, Anthropic Messages, OpenAI Responses),
/// storage telemetry, and capture shortcuts.
public struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void

    private static let gdirectTutorialURL = URL(
        string: "https://github.com/mizorewww/gdirect/blob/main/docs/configuration/google-cloud.md"
    )!

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case cloudSync
        case intelligence
        case appearance
        case externalAgent
        case storage
        case captureShortcuts

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .cloudSync: "存储与同步"
            case .intelligence: "智能与搜索"
            case .appearance: "外观与图标"
            case .externalAgent: "外部 Agent 与 MCP"
            case .storage: "缓存空间"
            case .captureShortcuts: "采集与快捷键"
            }
        }

        public var icon: String {
            switch self {
            case .cloudSync: "drive-sync"
            case .intelligence: "sparkle-board"
            case .appearance: "moodboard"
            case .externalAgent: "connector"
            case .storage: "library"
            case .captureShortcuts: "notch"
            }
        }
    }

    private let appIconManager = CharkleAppIconManager.shared

    @State private var selectedTab: SettingsTab = .cloudSync
    @State private var draftSyncConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var draftAIConfig: AIProviderConfig = AIProviderConfig()
    @State private var draftTypeSafeConfig: TypeSafeExperimentalConfig = TypeSafeExperimentalConfig()
    @State private var draftExternalAgentConfig: ExternalAgentConfig = ExternalAgentConfig()
    @State private var apiKeyInput: String = ""
    @State private var typeSafeAPIKeyInput: String = ""
    @State private var showTypeSafeAdvanced: Bool = false
    @State private var webDAVPasswordInput: String = ""
    @State private var cacheBudgetGB: Double = 10.0
    @State private var didLoadInitial: Bool = false

    @State private var showSyncAdvanced: Bool = false
    @State private var showAIAdvanced: Bool = false
    @State private var showOAuthSetupSheet: Bool = false
    @State private var oauthClientIDInput: String = ""
    @State private var oauthClientSecretInput: String = ""

    // Lossless Storage Migration Sheet state
    @State private var showMigrationSheet: Bool = false
    @State private var migrationDraftConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var migrationWebDAVPassword: String = ""

    public init(
        coordinator: AppCoordinatorStore,
        syncAndAI: SyncAndAIStore,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void
    ) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Navigation Rail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    CharkleBrandMark(size: 22)
                    Text("设置")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ForEach(SettingsTab.allCases) { tab in
                    let active = selectedTab == tab
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 9) {
                            CharkleIcon(tab.icon, style: .duotone, size: 15, color: active ? Color.accentColor : .secondary)
                            Text(tab.label)
                                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.84))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            active ? Color.accentColor.opacity(0.13) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }

                Spacer()
            }
            .frame(width: 192)
            .background(CharkleTheme.inspectorBackground(for: colorScheme))

            Divider()

            // Right Content Pane
            let hasFeedbackBanner = syncAndAI.statusMessage != nil || syncAndAI.errorMessage != nil
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    if let status = syncAndAI.statusMessage {
                        feedbackBanner(status, isError: false)
                            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                    }
                    if let err = syncAndAI.errorMessage {
                        feedbackBanner(err, isError: true)
                            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                    }

                    switch selectedTab {
                    case .cloudSync:
                        cloudSyncPane
                    case .intelligence:
                        intelligencePane
                    case .appearance:
                        appearancePane
                    case .externalAgent:
                        externalAgentPane
                    case .storage:
                        storagePane
                    case .captureShortcuts:
                        captureAndShortcutsPane
                    }
                }
                .padding(24)
                .animation(
                    CharkleMotion.enterExit(hasFeedbackBanner, reduced: reduceMotion),
                    value: "\(syncAndAI.statusMessage ?? "")|\(syncAndAI.errorMessage ?? "")"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CharkleTheme.galleryGround(for: colorScheme))
        }
        .frame(width: 760, height: 630)
        .task {
            await syncAndAI.loadAll()
            draftSyncConfig = syncAndAI.syncConfig
            draftAIConfig = syncAndAI.aiConfig
            draftTypeSafeConfig = syncAndAI.typeSafeConfig
            draftExternalAgentConfig = syncAndAI.externalAgentConfig
            cacheBudgetGB = max(2, min(100, Double(syncAndAI.cacheStats.budgetBytes) / (1024 * 1024 * 1024)))
            didLoadInitial = true
        }
        .sheet(isPresented: $showOAuthSetupSheet) {
            googleOAuthSetupSheet
        }
        .sheet(isPresented: $showMigrationSheet) {
            storageMigrationSheet
        }
    }

    // MARK: - Tab 1: 存储与同步 (Google Drive / WebDAV / 纯本地文件夹 + 无损迁移)

    private var cloudSyncPane: some View {
        let snap = syncAndAI.gdirectSnapshot
        let healthyNodeCount = snap.endpoints.filter(\.healthy).count
        let activeBackendBinding = Binding<DriveTransportMode>(
            get: { draftSyncConfig.mode == .gdirectMount ? .directAPIWithGDirect : draftSyncConfig.mode },
            set: { newMode in
                if newMode == .directAPIWithGDirect && draftSyncConfig.mode == .gdirectMount {
                    return
                }
                draftSyncConfig.mode = newMode
                persistSyncConfigIfReady()
            }
        )

        return VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "存储与同步",
                subtitle: "自由选择 Google Drive、WebDAV 云盘或纯本地文件夹保存素材库，可自定义保存路径并随时无损转移。"
            )

            // 3-Way Primary Storage Mode Selector
            settingsGroupCard {
                settingsRow(
                    title: "素材库存储方式",
                    subtitle: storageModeDescription(draftSyncConfig.mode)
                ) {
                    Picker("", selection: activeBackendBinding) {
                        Text("Google Drive").tag(DriveTransportMode.directAPIWithGDirect)
                        Text("WebDAV 云盘").tag(DriveTransportMode.webDAV)
                        Text("纯本地文件夹").tag(DriveTransportMode.localOnly)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 286)
                }

                Divider()

                switch draftSyncConfig.mode {
                case .directAPIWithGDirect, .gdirectMount:
                    googleDriveSection
                case .webDAV:
                    webDAVSection
                case .localOnly:
                    localLibrarySection
                }
            }

            // Live Cloud Sync Progress Card (visible whenever cloud storage is active)
            if draftSyncConfig.mode != .localOnly {
                cloudSyncProgressCard
            }

            // Sync Preferences (when using Cloud)
            if draftSyncConfig.mode != .localOnly {
                settingsGroupCard {
                    settingsRow(
                        title: "同步轻量化预览图",
                        subtitle: "切换其他 Mac 时立即看到完整画廊，无需等待下载原文件"
                    ) {
                        Toggle("", isOn: $draftSyncConfig.syncThumbnails)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: draftSyncConfig.syncThumbnails) { _, _ in persistSyncConfigIfReady() }
                    }

                    Divider()

                    settingsRow(
                        title: "同步智能搜索索引",
                        subtitle: "在多台设备间共享搜索索引，保持一致的搜图与情绪板推荐体验"
                    ) {
                        Toggle("", isOn: $draftSyncConfig.syncEmbeddings)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: draftSyncConfig.syncEmbeddings) { _, _ in persistSyncConfigIfReady() }
                    }
                }
            }

            // Lossless Migration Card (Local <-> Cloud, or Change Path)
            settingsGroupCard {
                settingsRow(
                    title: "转移素材库存储位置",
                    subtitle: "将现有素材、文件夹和情绪板从纯本地无损迁移到云盘，或从云盘完整迁回本地文件夹。"
                ) {
                    Button {
                        migrationDraftConfig = draftSyncConfig
                        migrationWebDAVPassword = ""
                        showMigrationSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                            Text("开始转移…")
                        }
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(syncAndAI.isBusy)
                }

                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text("当前保存位置：\(draftSyncConfig.activeStorageLocationSummary)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Collapsible Advanced Options
            settingsGroupCard {
                DisclosureGroup(isExpanded: $showSyncAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().padding(.top, 4)

                        settingsRow(
                            title: "Google 登录凭据（gdirect 桌面端凭据）",
                            subtitle: syncAndAI.hasGoogleOAuthClient
                                ? "已配置，可直接点击上方「使用 Google 账号登录」"
                                : "可从本机 gdirect 导入，或按 gdirect 教程配置一次"
                        ) {
                            HStack(spacing: 6) {
                                if snap.cliPath != nil && !syncAndAI.hasGoogleOAuthClient {
                                    Button("从本机 gdirect 导入") {
                                        Task { _ = await syncAndAI.importGoogleOAuthFromGDirect() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .fixedSize()
                                }
                                Button(syncAndAI.hasGoogleOAuthClient ? "更换凭据…" : "配置凭据…") {
                                    showOAuthSetupSheet = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize()
                            }
                        }

                        if snap.cliPath != nil {
                            Divider()

                            settingsRow(
                                title: "gdirect 直连兜底诊断",
                                subtitle: healthyNodeCount > 0
                                    ? "检测到本机 gdirect，当前有 \(healthyNodeCount) 个可用兜底节点（仅在标准 HTTPS 直连受阻时自动启用）"
                                    : "可手动扫描优选节点，供网络直连受阻时自动回退兜底"
                            ) {
                                HStack(spacing: 8) {
                                    Button("重新测速优选") {
                                        Task { await syncAndAI.runGDirectScan() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("刷新状态") {
                                        Task { await syncAndAI.probeGDirect() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .disabled(syncAndAI.isBusy)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text("高级选项")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: - Google Drive Sub-Section

    @ViewBuilder
    private var googleDriveSection: some View {
        let snap = syncAndAI.gdirectSnapshot
        let healthyNodeCount = snap.endpoints.filter(\.healthy).count
        let gdirectEmail = draftSyncConfig.selectedGDirectAccount ?? snap.defaultAccount ?? snap.accounts.first
        let isGDirectMountMode = draftSyncConfig.mode == .gdirectMount
        let directAccount: DriveAccountInfo? = {
            guard let acc = syncAndAI.syncStatus.account,
                  acc.source != "WebDAV",
                  acc.source != "本地文件夹",
                  acc.source != "gdirect",
                  acc.source != "gdirect mount" else { return nil }
            return acc
        }()
        let activeAccount: DriveAccountInfo? = {
            if isGDirectMountMode {
                return gdirectEmail.map { DriveAccountInfo(email: $0, displayName: nil, source: "gdirect mount") }
            }
            return directAccount
                ?? gdirectEmail.map { DriveAccountInfo(email: $0, displayName: nil, source: "gdirect") }
        }()
        let isUsingGDirectFallbackInDirectMode = !isGDirectMountMode && directAccount == nil && activeAccount != nil
        let isUsingLocalGDirect = isGDirectMountMode || isUsingGDirectFallbackInDirectMode
        let isSignedIn = activeAccount != nil
        let driveAccessModeBinding = Binding<DriveTransportMode>(
            get: { draftSyncConfig.mode == .gdirectMount ? .gdirectMount : .directAPIWithGDirect },
            set: { newMode in
                draftSyncConfig.mode = newMode
                persistSyncConfigIfReady()
            }
        )

        settingsRow(
            title: "Google Drive 接入方式",
            subtitle: isGDirectMountMode
                ? "通过本机 gdirect 挂载读写（与正常 Google 账号直连可共存，互不覆盖登录态）"
                : "正常 HTTPS API 直连 Google Drive（推荐、免挂载）；可同时保留本机 gdirect 作为兜底"
        ) {
            Picker("", selection: driveAccessModeBinding) {
                Text("正常直连（推荐）").tag(DriveTransportMode.directAPIWithGDirect)
                Text("gdirect 模式").tag(DriveTransportMode.gdirectMount)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 244)
        }

        Divider()

        if isGDirectMountMode {
            // Dedicated gdirect mount mode (coexists with Charkle's Google OAuth token)
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(snap.isMountActive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                        .frame(width: 42, height: 42)
                    Image(systemName: snap.isMountActive ? "externaldrive.badge.checkmark" : "externaldrive")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(snap.isMountActive ? Color.accentColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(gdirectEmail ?? (snap.cliPath == nil ? "未检测到本机 gdirect" : "未登录本机 gdirect 账号"))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(snap.isMountActive ? "已挂载" : "未挂载")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(snap.isMountActive ? .green : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((snap.isMountActive ? Color.green : Color.primary).opacity(0.10), in: Capsule(style: .continuous))
                    }
                    Text(
                        snap.cliPath == nil
                            ? "未在本机找到 gdirect CLI，可先安装 gdirect 或切换为「正常直连（推荐）」"
                            : (snap.isMountActive
                                ? "挂载路径：\(draftSyncConfig.mountPath)（与直连 OAuth 账号可共存）"
                                : "当前尚未挂载本地卷，点击右侧「立即挂载」或直接切回正常直连 API")
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 8) {
                    if snap.isMountActive {
                        Button {
                            Task { _ = await syncAndAI.syncNow() }
                        } label: {
                            HStack(spacing: 5) {
                                if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                                Text("立即同步")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)

                        Button("卸载") {
                            Task { await syncAndAI.runGDirectUnmount() }
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)
                    } else if snap.cliPath != nil, gdirectEmail != nil {
                        Button {
                            Task { await syncAndAI.runGDirectMount(path: draftSyncConfig.mountPath) }
                        } label: {
                            HStack(spacing: 5) {
                                if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                                Text("立即挂载")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)
                    } else {
                        Button("刷新状态") {
                            Task { await syncAndAI.probeGDirect() }
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)
                    }
                }
            }

            if snap.accounts.count > 1 {
                settingsRow(
                    title: "本机 gdirect 账号",
                    subtitle: "选择用于挂载与同步的 gdirect 账号"
                ) {
                    Picker("", selection: Binding(
                        get: { gdirectEmail ?? snap.accounts.first ?? "" },
                        set: { newEmail in
                            draftSyncConfig.selectedGDirectAccount = newEmail
                            persistSyncConfigIfReady()
                        }
                    )) {
                        ForEach(snap.accounts, id: \.self) { email in
                            Text(email).tag(email)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            settingsRow(
                title: "本地挂载目录",
                subtitle: "gdirect 将 Google Drive 映射到此目录（默认 ~/GoogleDrive）"
            ) {
                TextField(NSHomeDirectory() + "/GoogleDrive", text: $draftSyncConfig.mountPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { persistSyncConfigIfReady() }
            }

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Text("休眠唤醒后若 macOS 提示 NFS 断连，可随时切换回「正常直连（推荐）」免挂载同步，并保留 gdirect 作为兜底。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("切回正常直连") {
                    draftSyncConfig.mode = .directAPIWithGDirect
                    persistSyncConfigIfReady()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            // Normal Direct Google Drive API mode (with optional gdirect fallback)
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSignedIn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                        .frame(width: 42, height: 42)
                    Image(systemName: isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(isSignedIn ? Color.accentColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(activeAccount?.displayName ?? activeAccount?.email ?? "未登录 Google 账号")
                            .font(.system(size: 13.5, weight: .semibold))
                        if isSignedIn {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                        }
                        if isUsingGDirectFallbackInDirectMode {
                            Text("gdirect 兜底")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.11), in: Capsule(style: .continuous))
                        }
                    }
                    if let account = activeAccount, let name = account.displayName, !name.isEmpty {
                        Text(account.email)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Text(googleHeroSubtitle(account: activeAccount, isUsingLocalGDirect: isUsingGDirectFallbackInDirectMode))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if directAccount != nil {
                    HStack(spacing: 8) {
                        Button {
                            Task { _ = await syncAndAI.syncNow() }
                        } label: {
                            HStack(spacing: 5) {
                                if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                                Text("立即同步")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)

                        Menu {
                            Button("切换 Google 账号…") {
                                triggerGoogleSignIn()
                            }
                            if snap.isMountActive {
                                Button("卸载本机 GoogleDrive 挂载") {
                                    Task { await syncAndAI.runGDirectUnmount() }
                                }
                            }
                            Divider()
                            Button("退出登录", role: .destructive) {
                                Task { await syncAndAI.signOutGoogleDrive() }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            triggerGoogleSignIn()
                        } label: {
                            HStack(spacing: 6) {
                                if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                                Text("使用 Google 账号登录")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(syncAndAI.isBusy)

                        if isUsingGDirectFallbackInDirectMode && snap.isMountActive {
                            Button("立即同步") {
                                Task { _ = await syncAndAI.syncNow() }
                            }
                            .buttonStyle(.bordered)
                            .fixedSize()
                            .disabled(syncAndAI.isBusy)
                        }
                    }
                }
            }

            if isUsingGDirectFallbackInDirectMode {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前暂以本机 gdirect 兜底，可随时登录独立 Google 账号")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("登录独立 Google 账号后将启用 HTTP/2 免挂载高速直连，且仍保留本机 gdirect 在网络受限时自动兜底。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if snap.cliPath != nil {
                Divider()

                settingsRow(
                    title: "网络受限时使用本机 gdirect 兜底",
                    subtitle: draftSyncConfig.useGDirectIPAcceleration
                        ? (healthyNodeCount > 0
                            ? "默认优先普通 HTTPS 直连；仅当直连受阻时自动回退至 gdirect（\(healthyNodeCount) 个可用节点）"
                            : "默认优先普通 HTTPS 直连；当无法直接访问 googleapis.com 时自动尝试本机 gdirect")
                        : "已关闭，仅使用标准 Google Drive HTTPS 直连"
                ) {
                    Toggle("", isOn: $draftSyncConfig.useGDirectIPAcceleration)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: draftSyncConfig.useGDirectIPAcceleration) { _, _ in persistSyncConfigIfReady() }
                }
            }
        }

        if let used = activeAccount?.storageUsedBytes,
           let limit = activeAccount?.storageLimitBytes, limit > 0 {
            let ratio = min(1.0, max(0.0, Double(used) / Double(limit)))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Google Drive 云端空间")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: ratio)
                    .progressViewStyle(.linear)
            }
        }

        Divider()

        settingsRow(
            title: "云端保存路径",
            subtitle: draftSyncConfig.resolvedSharedFolderID != nil
                ? "当前已绑定下方共享协作目录；清除共享目录后将恢复使用此路径"
                : "支持单级目录（Charkle）、多级路径（Design/Charkle），或已添加到「我的云端硬盘」的共享目录快捷方式名"
        ) {
            TextField("Charkle", text: $draftSyncConfig.rootFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
                .disabled(draftSyncConfig.resolvedSharedFolderID != nil)
                .onSubmit { persistSyncConfigIfReady() }
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            settingsRow(
                title: "共享协作目录（可选）",
                subtitle: "粘贴 Google Drive「与我共享」目录链接或 ID，多人指向同一共享目录即可共同写入、整理与浏览"
            ) {
                HStack(spacing: 6) {
                    TextField("https://drive.google.com/drive/folders/… 或目录 ID", text: $draftSyncConfig.sharedFolderURLOrID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .onSubmit { persistSyncConfigIfReady() }

                    if !draftSyncConfig.sharedFolderURLOrID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("清除") {
                            draftSyncConfig.sharedFolderURLOrID = ""
                            persistSyncConfigIfReady()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 8) {
                if let sharedID = draftSyncConfig.resolvedSharedFolderID {
                    Label("协作模式已启用（ID: \(String(sharedID.prefix(12)))…）", systemImage: "person.2.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                } else if !draftSyncConfig.sharedFolderURLOrID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("链接或 ID 格式无效，请检查是否包含 /folders/…", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Text(
                        isUsingLocalGDirect
                            ? "提示：在 gdirect 挂载模式下，将共享目录在 Google Drive 网页端「添加到云端硬盘快捷方式」后，也可直接在上方填写快捷方式名协作。"
                            : "提示：在 Google Drive 目录中直接拖入新素材文件，Charkle 也会自动扫描并生成缩略图与视觉索引。"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                if !isUsingLocalGDirect && isSignedIn {
                    Menu {
                        if syncAndAI.sharedFolders.isEmpty {
                            Button("加载「与我共享」目录列表…") {
                                Task { await syncAndAI.loadSharedFolders() }
                            }
                        } else {
                            ForEach(syncAndAI.sharedFolders, id: \.id) { folder in
                                Button {
                                    draftSyncConfig.sharedFolderURLOrID = folder.webViewLink ?? folder.id
                                    persistSyncConfigIfReady()
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
                        HStack(spacing: 4) {
                            if syncAndAI.isLoadingSharedFolders {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "person.2.badge.gearshape")
                                    .font(.system(size: 11))
                            }
                            Text("选择与我共享")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .onTapGesture {
                        if syncAndAI.sharedFolders.isEmpty && !syncAndAI.isLoadingSharedFolders {
                            Task { await syncAndAI.loadSharedFolders() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - WebDAV Sub-Section

    @ViewBuilder
    private var webDAVSection: some View {
        let isWebDAVConnected = syncAndAI.syncStatus.account?.source == "WebDAV"

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isWebDAVConnected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                        .frame(width: 38, height: 38)
                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isWebDAVConnected ? Color.accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("WebDAV 云盘同步")
                        .font(.system(size: 13, weight: .semibold))
                    Text("兼容坚果云、Nextcloud、群晖 NAS、Alist 等任意标准 WebDAV 服务")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button("测试连接") {
                        let pwd = webDAVPasswordInput
                        let cfg = draftSyncConfig
                        Task {
                            let ok = await syncAndAI.testWebDAVConnection(config: cfg, password: pwd.isEmpty ? nil : pwd)
                            if ok { webDAVPasswordInput = "" }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(draftSyncConfig.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncAndAI.isBusy)

                    Button {
                        let pwd = webDAVPasswordInput
                        let cfg = draftSyncConfig
                        Task {
                            if !pwd.isEmpty {
                                _ = await syncAndAI.saveWebDAVPassword(pwd)
                                webDAVPasswordInput = ""
                            }
                            await syncAndAI.saveSyncConfig(cfg, quiet: true)
                            _ = await syncAndAI.syncNow()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                            Text("立即同步")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(draftSyncConfig.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncAndAI.isBusy)
                }
            }

            settingsRow(title: "服务器地址", subtitle: "例如 https://dav.jianguoyun.com/dav/") {
                TextField("https://dav.jianguoyun.com/dav/", text: $draftSyncConfig.webDAVServerURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 248)
                    .onSubmit { persistSyncConfigIfReady() }
            }

            settingsRow(title: "账号 / 用户名", subtitle: nil) {
                TextField("邮箱或用户名", text: $draftSyncConfig.webDAVUsername)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 248)
                    .onSubmit { persistSyncConfigIfReady() }
            }

            settingsRow(
                title: "应用密码",
                subtitle: syncAndAI.hasWebDAVPassword ? "已安全保存在 macOS 钥匙串" : "仅保存在本机钥匙串，绝不明文落盘"
            ) {
                HStack(spacing: 6) {
                    SecureField(syncAndAI.hasWebDAVPassword ? "••••••••（留空不变）" : "输入密码或应用授权码", text: $webDAVPasswordInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 184)
                    Button("保存") {
                        let pwd = webDAVPasswordInput
                        let cfg = draftSyncConfig
                        Task {
                            await syncAndAI.saveSyncConfig(cfg, quiet: true)
                            if await syncAndAI.saveWebDAVPassword(pwd) {
                                webDAVPasswordInput = ""
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(webDAVPasswordInput.isEmpty)
                }
            }

            settingsRow(title: "云端保存路径", subtitle: "素材库将按可读目录保存在此路径下") {
                TextField("/Charkle", text: $draftSyncConfig.webDAVRemotePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 248)
                    .onSubmit { persistSyncConfigIfReady() }
            }
        }
    }

    // MARK: - Pure Local Folder Sub-Section

    @ViewBuilder
    private var localLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsRow(
                title: "本机素材库目录",
                subtitle: "所有原始文件与文件夹结构以人类可读方式保存在此本机目录中"
            ) {
                HStack(spacing: 6) {
                    Button("选择文件夹…") {
                        if let picked = pickLocalDirectory(initialPath: draftSyncConfig.localLibraryPath) {
                            draftSyncConfig.localLibraryPath = picked
                            persistSyncConfigIfReady()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()

                    Button("在访达中打开") {
                        let url = URL(fileURLWithPath: (draftSyncConfig.localLibraryPath as NSString).expandingTildeInPath, isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            HStack(spacing: 8) {
                TextField("~/Pictures/Charkle", text: $draftSyncConfig.localLibraryPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { persistSyncConfigIfReady() }

                Button {
                    let cfg = draftSyncConfig
                    Task {
                        await syncAndAI.saveSyncConfig(cfg, quiet: true)
                        _ = await syncAndAI.syncNow()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if syncAndAI.isBusy { ProgressView().controlSize(.mini) }
                        Text("同步到该目录")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .fixedSize()
                .disabled(syncAndAI.isBusy)
            }
        }
    }

    // MARK: - Google OAuth Setup Sheet (gdirect Import + Tutorial Link)

    private var googleOAuthSetupSheet: some View {
        let hasGDirect = syncAndAI.gdirectSnapshot.cliPath != nil

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("配置 Google Drive 登录凭据")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Charkle 基于 gdirect 生态直连 Google Drive，配置一次桌面端凭据即可完成账号登录。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Guided Tutorial & One-Click Local gdirect Import Card
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Link(destination: Self.gdirectTutorialURL) {
                        HStack(spacing: 5) {
                            Image(systemName: "book.pages")
                            Text("查看 gdirect 官方 Google Cloud 配置教程")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    if hasGDirect {
                        Button {
                            Task {
                                let ok = await syncAndAI.importGoogleOAuthFromGDirect()
                                if ok {
                                    showOAuthSetupSheet = false
                                    _ = await syncAndAI.signInGoogleDrive()
                                }
                            }
                        } label: {
                            Label("从本机已配置的 gdirect 一键导入", systemImage: "arrow.down.doc.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(syncAndAI.isBusy)
                    }

                    Button {
                        presentOAuthSecretImporter(autoSignInAfterImport: true)
                    } label: {
                        Label("导入 client_secret.json 文件…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text("或手动粘贴教程中创建的桌面端凭据")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Client ID")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("例如：1234567890-xxxx.apps.googleusercontent.com", text: $oauthClientIDInput)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Client Secret")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    SecureField("例如：GOCSPX-xxxxxxxx", text: $oauthClientSecretInput)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("取消") {
                    showOAuthSetupSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存并前往 Google 登录") {
                    let cid = oauthClientIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let secret = oauthClientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        let saved = await syncAndAI.saveGoogleOAuthClientConfig(clientID: cid, clientSecret: secret)
                        if saved {
                            showOAuthSetupSheet = false
                            oauthClientIDInput = ""
                            oauthClientSecretInput = ""
                            _ = await syncAndAI.signInGoogleDrive()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(oauthClientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncAndAI.isBusy)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    // MARK: - Lossless Storage Migration Sheet (Local <-> Google Drive <-> WebDAV)

    private var storageMigrationSheet: some View {
        let targetModeBinding = Binding<DriveTransportMode>(
            get: { migrationDraftConfig.mode == .gdirectMount ? .directAPIWithGDirect : migrationDraftConfig.mode },
            set: { migrationDraftConfig.mode = $0 }
        )

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("转移素材库存储位置")
                        .font(.system(size: 15, weight: .semibold))
                    Text("当前位置：\(draftSyncConfig.activeStorageLocationSummary)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("目标存储方式")
                    .font(.system(size: 12, weight: .semibold))
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
                switch migrationDraftConfig.mode {
                case .directAPIWithGDirect, .gdirectMount:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目标 Google Drive 路径")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("Charkle 或 Design/Charkle", text: $migrationDraftConfig.rootFolderName)
                            .textFieldStyle(.roundedBorder)
                    }
                    let hasReadyGoogleAccount = (syncAndAI.syncStatus.account != nil && syncAndAI.syncStatus.account?.source != "WebDAV" && syncAndAI.syncStatus.account?.source != "本地文件夹")
                        || syncAndAI.gdirectSnapshot.defaultAccount != nil
                        || !syncAndAI.gdirectSnapshot.accounts.isEmpty
                    if !hasReadyGoogleAccount {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.orange)
                            Text("迁移到 Google Drive 前请先登录 Google 账号。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("先去登录") {
                                showMigrationSheet = false
                                triggerGoogleSignIn()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }

                case .webDAV:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("WebDAV 服务器地址（如 https://dav.jianguoyun.com/dav/）", text: $migrationDraftConfig.webDAVServerURL)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 8) {
                            TextField("用户名", text: $migrationDraftConfig.webDAVUsername)
                                .textFieldStyle(.roundedBorder)
                            SecureField(syncAndAI.hasWebDAVPassword ? "密码（留空沿用已存密码）" : "应用密码", text: $migrationWebDAVPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("远端保存路径（如 /Charkle）", text: $migrationDraftConfig.webDAVRemotePath)
                            .textFieldStyle(.roundedBorder)
                    }

                case .localOnly:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目标本机文件夹路径")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("~/Pictures/Charkle", text: $migrationDraftConfig.localLibraryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("选择文件夹…") {
                                if let picked = pickLocalDirectory(initialPath: migrationDraftConfig.localLibraryPath) {
                                    migrationDraftConfig.localLibraryPath = picked
                                }
                            }
                            .buttonStyle(.bordered)
                            .fixedSize()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("迁移流程说明")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("1. 先验证目标位置连通与可写性，避免中断损坏原库；\n2. 自动补全拉取尚未缓存在本机的云端原件；\n3. 将全部文件夹、素材原件与情绪板完整写入新位置并切换为默认存储。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack {
                Button("取消") {
                    showMigrationSheet = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(syncAndAI.isMigrating)

                Spacer()

                Button {
                    let target = migrationDraftConfig
                    let pwd = migrationWebDAVPassword
                    Task {
                        if await syncAndAI.migrateLibraryStorage(to: target, webDAVPassword: pwd.isEmpty ? nil : pwd) != nil {
                            draftSyncConfig = syncAndAI.syncConfig
                            showMigrationSheet = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if syncAndAI.isMigrating {
                            ProgressView().controlSize(.mini)
                        }
                        Text(syncAndAI.isMigrating ? "正在迁移素材库…" : "开始无损转移")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(syncAndAI.isBusy || !canStartMigration)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var canStartMigration: Bool {
        switch migrationDraftConfig.mode {
        case .localOnly:
            return !migrationDraftConfig.localLibraryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .webDAV:
            return !migrationDraftConfig.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .directAPIWithGDirect, .gdirectMount:
            return !migrationDraftConfig.rootFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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

    // MARK: - Tab 2: 智能与搜索

    private var intelligencePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "智能与搜索",
                subtitle: "日常配色筛选、文字识别与相似推荐完全在你的 Mac 本机离线运行，零隐私外传；需要更深画面理解时可按需开启云端增强智能。"
            )

            // Built-in Offline Capabilities
            settingsGroupCard {
                Text("本机内置智能（始终免费 · 离线可用）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        capabilityTile(icon: "paintpalette", title: "自动配色提取", detail: "按画面主色调筛选与生成和谐色卡", minHeight: 58)
                        capabilityTile(icon: "sparkles.rectangle.stack", title: "视觉相似推荐", detail: "离线发现构图与风格接近的参考素材", minHeight: 58)
                    }
                    GridRow {
                        capabilityTile(icon: "text.viewfinder", title: "图内文字识别", detail: "自动识别中英文海报、截图中的文字", minHeight: 58)
                        capabilityTile(icon: "magnifyingglass", title: "中文与拼音快搜", detail: "按关键词或拼音首字母秒搜任意灵感", minHeight: 58)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            // Optional Cloud AI Enhancement
            settingsGroupCard {
                settingsRow(
                    title: "云端增强智能",
                    subtitle: "自动生成画面描述与建议标签，让灵感词生板更懂你的想法"
                ) {
                    Picker("", selection: $draftAIConfig.provider) {
                        Text("关闭（仅本机）").tag(CloudAIProviderKind.disabled)
                        Text("ChatGPT 订阅账号").tag(CloudAIProviderKind.chatGPTSubscription)
                        Text("Google Gemini").tag(CloudAIProviderKind.gemini)
                        Text("自定义兼容服务").tag(CloudAIProviderKind.openAICompatible)
                    }
                    .labelsHidden()
                    .frame(width: 196)
                    .onChange(of: draftAIConfig.provider) { _, newProvider in
                        applySmartAIDefaults(for: newProvider, format: draftAIConfig.customEndpointFormat)
                        Task {
                            await syncAndAI.refreshAIKeyPresence(for: newProvider)
                            if didLoadInitial {
                                await syncAndAI.saveAIConfig(draftAIConfig, apiKey: nil, quiet: true)
                            }
                        }
                    }
                }

                if draftAIConfig.provider == .chatGPTSubscription {
                    Divider()

                    chatGPTSubscriptionSection
                }

                if draftAIConfig.provider != .disabled {
                    if draftAIConfig.provider == .openAICompatible {
                        Divider()

                        settingsRow(
                            title: "端点格式",
                            subtitle: endpointFormatSubtitle(draftAIConfig.customEndpointFormat)
                        ) {
                            Picker("", selection: $draftAIConfig.customEndpointFormat) {
                                ForEach(CustomAIEndpointFormat.allCases, id: \.self) { fmt in
                                    Text(fmt.localizedLabel).tag(fmt)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 236)
                            .onChange(of: draftAIConfig.customEndpointFormat) { _, newFormat in
                                applySmartAIDefaults(for: .openAICompatible, format: newFormat)
                                persistAIConfigIfReady()
                            }
                        }
                    }

                    if draftAIConfig.provider != .chatGPTSubscription {
                        Divider()

                        settingsRow(
                            title: "API 密钥",
                            subtitle: syncAndAI.hasStoredAIKey
                                ? "已安全保存在 macOS 钥匙串中"
                                : "密钥仅存于本机钥匙串，绝不上传"
                        ) {
                            HStack(spacing: 8) {
                                SecureField(syncAndAI.hasStoredAIKey ? "••••••••（留空不变）" : "粘贴密钥…", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 176)
                                Button("保存") {
                                    let keyToSave = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    Task {
                                        await syncAndAI.saveAIConfig(draftAIConfig, apiKey: keyToSave.isEmpty ? nil : keyToSave)
                                        apiKeyInput = ""
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .fixedSize()
                            }
                        }
                    }

                    if draftAIConfig.provider == .openAICompatible {
                        Divider()

                        settingsRow(title: "服务地址", subtitle: "自动补全 /v1 路径，也可直接填写完整前缀") {
                            TextField(draftAIConfig.customEndpointFormat.defaultBaseURL, text: $draftAIConfig.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit { persistAIConfigIfReady() }
                        }

                        Divider()

                        settingsRow(title: "理解模型", subtitle: nil) {
                            TextField(draftAIConfig.customEndpointFormat.defaultChatModel, text: $draftAIConfig.chatModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit { persistAIConfigIfReady() }
                        }

                        if draftAIConfig.customEndpointFormat.supportsEmbeddings {
                            Divider()

                            settingsRow(title: "搜索向量模型（可选）", subtitle: "留空时仅使用本机视觉特征搜索") {
                                TextField("text-embedding-3-small", text: $draftAIConfig.embeddingModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                                    .onSubmit { persistAIConfigIfReady() }
                            }
                        }
                    }

                    Divider()

                    settingsRow(
                        title: "导入时自动分析",
                        subtitle: "收藏新素材后自动补充描述与标签建议"
                    ) {
                        Toggle("", isOn: $draftAIConfig.autoAnalyzeOnImport)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: draftAIConfig.autoAnalyzeOnImport) { _, _ in persistAIConfigIfReady() }
                    }

                    Divider()

                    settingsRow(
                        title: "仅上传轻量化预览图",
                        subtitle: "节省网络流量，避免发送原始大图"
                    ) {
                        Toggle("", isOn: $draftAIConfig.sendThumbnailsToCloud)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: draftAIConfig.sendThumbnailsToCloud) { _, _ in persistAIConfigIfReady() }
                    }

                    if draftAIConfig.provider == .gemini {
                        Divider()

                        DisclosureGroup(isExpanded: $showAIAdvanced) {
                            VStack(spacing: 10) {
                                settingsRow(title: "服务地址", subtitle: nil) {
                                    TextField("https://generativelanguage.googleapis.com", text: $draftAIConfig.baseURL)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                        .onSubmit { persistAIConfigIfReady() }
                                }
                                settingsRow(title: "理解模型", subtitle: nil) {
                                    TextField("gemini-2.5-flash", text: $draftAIConfig.chatModel)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                        .onSubmit { persistAIConfigIfReady() }
                                }
                                settingsRow(title: "搜索向量模型", subtitle: nil) {
                                    TextField("gemini-embedding-001", text: $draftAIConfig.embeddingModel)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                        .onSubmit { persistAIConfigIfReady() }
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                                Text("高级模型参数")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                if draftAIConfig.provider != .disabled
                    || draftTypeSafeConfig.enabled
                    || syncAndAI.aiUsage.standard.totalRequests > 0
                    || syncAndAI.aiUsage.jev.totalRequests > 0 {
                    Divider()
                    cloudAIUsageSection
                }
            }

            // Experimental System One Sidecar: TypeSafe (Jev) Box & Grounding
            typeSafeExperimentalCard
        }
    }

    // MARK: - Live Cloud Sync Progress Card

    private var cloudSyncProgressCard: some View {
        let status = syncAndAI.syncStatus
        let isSyncing = status.isSyncing || syncAndAI.isBusy
        let percentText: String? = status.progressFraction.map { "\(Int(($0 * 100).rounded()))%" }

        return settingsGroupCard {
            HStack(alignment: .center, spacing: 10) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(cloudSyncIndicatorColor(status))
                        .frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isSyncing ? status.localizedPhaseTitle : cloudSyncIdleHeadline(status))
                            .font(.system(size: 12.5, weight: .semibold))
                        if isSyncing, let percentText {
                            Text(percentText)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(cloudSyncSubheadline(status: status, isSyncing: isSyncing))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    Task { _ = await syncAndAI.syncNow() }
                } label: {
                    Text(isSyncing ? "同步中…" : "立即同步")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(isSyncing)
            }

            if isSyncing {
                if let fraction = status.progressFraction {
                    ProgressView(value: min(1.0, max(0.0, fraction)))
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }
            }

            HStack(spacing: 12) {
                Label(
                    status.lastSyncedAt.map { "上次同步：\(relativeTimeText($0))" } ?? "尚未完成首次同步",
                    systemImage: "clock"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

                if status.pendingOpCount > 0 {
                    Label("待上传 \(status.pendingOpCount) 项", systemImage: "arrow.up.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                } else if !isSyncing, status.lastSyncedAt != nil {
                    Label("本地变更已全部同步", systemImage: "checkmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let report = syncAndAI.lastSyncReport {
                    Text("↑ \(report.uploadedOps)  ↓ \(report.downloadedOps)  +\(report.discoveredRemoteAssets) 新发现")
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func cloudSyncIndicatorColor(_ status: SyncStatus) -> Color {
        switch status.phase {
        case .error: return .red
        case .scanning, .uploading, .downloading, .merging: return .orange
        case .idle:
            if status.pendingOpCount > 0 { return .orange }
            return status.lastSyncedAt != nil ? .green : .secondary
        }
    }

    private func cloudSyncIdleHeadline(_ status: SyncStatus) -> String {
        if case .error = status.phase {
            return "上次同步遇到异常"
        }
        if status.pendingOpCount > 0 {
            return "有 \(status.pendingOpCount) 项本地变更待同步"
        }
        return status.lastSyncedAt != nil ? "已与云端保持同步" : "等待首次同步"
    }

    private func cloudSyncSubheadline(status: SyncStatus, isSyncing: Bool) -> String {
        if isSyncing {
            if let detail = status.currentDetail, !detail.isEmpty {
                return detail
            }
            return "正在与 \(draftSyncConfig.activeStorageLocationSummary) 同步…"
        }
        if let err = status.lastError, !err.isEmpty {
            return err
        }
        return "同步目标：\(draftSyncConfig.activeStorageLocationSummary)"
    }

    // MARK: - Cloud AI Usage Section (Standard vs Jev Separated)

    private var cloudAIUsageSection: some View {
        let usage = syncAndAI.aiUsage
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("用量统计")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                if usage.totalRequests > 0 {
                    Button("全部清零") {
                        syncAndAI.resetAIUsage(category: nil)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .help("清空普通模型与 Jev 判断模型的本地统计记录")
                }
            }

            usageBucketSection(
                icon: "sparkles",
                title: "普通云端模型",
                subtitle: "画面理解、标签建议与情绪板策展",
                bucket: usage.standard,
                emptyHint: "调用 Gemini / ChatGPT / 自定义模型后将单独统计在此。",
                onReset: { syncAndAI.resetAIUsage(category: .standard) }
            )

            usageBucketSection(
                icon: "viewfinder",
                title: "Jev 判断模型",
                subtitle: "TypeSafe System One 视觉定位、评分与分拣",
                bucket: usage.jev,
                emptyHint: "开启并调用 TypeSafe (Jev) 后将单独统计在此，不与普通模型混计。",
                onReset: { syncAndAI.resetAIUsage(category: .jev) }
            )
        }
    }

    private func usageBucketSection(
        icon: String,
        title: String,
        subtitle: String,
        bucket: CloudAIUsageBucket,
        emptyHint: String,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if bucket.totalRequests > 0 {
                    Button("清零", action: onReset)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                usageMetricTile(
                    title: "今日调用",
                    value: "\(bucket.todayRequests) 次",
                    detail: "今日 Token \(CloudAIUsageSummary.formatTokenCount(bucket.todayTotalTokens))"
                )
                usageMetricTile(
                    title: "累计调用",
                    value: "\(bucket.totalRequests) 次",
                    detail: bucket.lastModel ?? "尚未调用"
                )
                usageMetricTile(
                    title: "累计 Token",
                    value: CloudAIUsageSummary.formatTokenCount(bucket.totalTokens),
                    detail: "入 \(CloudAIUsageSummary.formatTokenCount(bucket.totalInputTokens)) / 出 \(CloudAIUsageSummary.formatTokenCount(bucket.totalOutputTokens))"
                )
            }
            .fixedSize(horizontal: false, vertical: true)

            if let usedAt = bucket.lastUsedAt {
                let provider = bucket.lastProviderLabel ?? title
                let modelPart = bucket.lastModel.map { " (\($0))" } ?? ""
                let tokenPart = bucket.lastCallTokens > 0 ? "，本次 \(CloudAIUsageSummary.formatTokenCount(bucket.lastCallTokens)) tokens" : ""
                Text("最近一次：\(provider)\(modelPart)\(tokenPart)（\(relativeTimeText(usedAt))）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(emptyHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
        )
    }

    private func usageMetricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func relativeTimeText(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 15 { return "刚刚" }
        if elapsed < 60 { return "\(Int(elapsed)) 秒前" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Tab 3: 外观与图标 (App Icon Switcher)

    private var appearancePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "外观与图标",
                subtitle: "自定义 Charkle 在程序坞、应用切换器与界面中的图标风格，切换后立即生效。"
            )

            settingsGroupCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("应用图标")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("默认使用柔和亮色图标，也可切换为深邃暗色背景版本。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        ForEach(CharkleAppIconVariant.allCases) { variant in
                            let selected = appIconManager.currentVariant == variant
                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                    appIconManager.select(variant)
                                }
                                syncAndAI.statusMessage = "已切换应用图标为「\(variant.title)」"
                            } label: {
                                VStack(spacing: 10) {
                                    ZStack(alignment: .topTrailing) {
                                        if let img = appIconManager.previewImage(for: variant) {
                                            Image(nsImage: img)
                                                .resizable()
                                                .interpolation(.high)
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 72, height: 72)
                                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                                .shadow(color: Color.black.opacity(0.14), radius: 8, y: 4)
                                        }

                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(.white, Color.accentColor)
                                                .offset(x: 6, y: -6)
                                        }
                                    }

                                    VStack(spacing: 2) {
                                        Text(variant.title)
                                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                                            .foregroundStyle(.primary)
                                        Text(variant.subtitle)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .padding(.vertical, 16)
                                .padding(.horizontal, 12)
                                .background(
                                    selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            selected ? Color.accentColor : CharkleTheme.hairline(for: colorScheme),
                                            lineWidth: selected ? 1.75 : 0.75
                                        )
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var typeSafeExperimentalCard: some View {
        settingsGroupCard {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("实验性视觉定位 · TypeSafe System One (Jev)")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Dreamer-ready")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.13), in: Capsule())
                    }
                    Text("与上方生成式 AI 互补：用 Jev Box + Noul 实现情绪板语义局部裁切、截图自动去噪、主体提色与指物批注。未开启时默认用本机 Apple Vision 兜底。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Toggle("", isOn: $draftTypeSafeConfig.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: draftTypeSafeConfig.enabled) { _, _ in
                        persistTypeSafeConfigIfReady()
                    }
            }

            if draftTypeSafeConfig.enabled {
                Divider()

                settingsRow(
                    title: "TypeSafe API 密钥",
                    subtitle: syncAndAI.hasStoredTypeSafeKey
                        ? "已安全保存在 macOS 钥匙串中（发送 TypeSafe-Danger-Zone-Images: true）"
                        : "密钥仅存于本机钥匙串，绝不上传"
                ) {
                    HStack(spacing: 8) {
                        SecureField(
                            syncAndAI.hasStoredTypeSafeKey ? "••••••••（留空不变）" : "粘贴 apikey_…",
                            text: $typeSafeAPIKeyInput
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 176)

                        Button("保存") {
                            let keyToSave = typeSafeAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await syncAndAI.saveTypeSafeConfig(
                                    draftTypeSafeConfig,
                                    apiKey: keyToSave.isEmpty ? nil : keyToSave
                                )
                                typeSafeAPIKeyInput = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()

                        Button {
                            let keyDraft = typeSafeAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                _ = await syncAndAI.testTypeSafeConnection(
                                    config: draftTypeSafeConfig,
                                    apiKey: keyDraft.isEmpty ? nil : keyDraft
                                )
                            }
                        } label: {
                            if syncAndAI.isTestingTypeSafe {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("测试连接")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(syncAndAI.isTestingTypeSafe)
                    }
                }

                Divider()

                settingsRow(
                    title: "Jev 模型",
                    subtitle: "Box 定位需要 Jev 1.14+（默认 jev-latest，需要锁定阈值时可填 jev-1.14.0）"
                ) {
                    HStack(spacing: 8) {
                        TextField("jev-latest", text: $draftTypeSafeConfig.model)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 168)
                            .onSubmit { persistTypeSafeConfigIfReady() }

                        if !syncAndAI.typeSafeModels.isEmpty {
                            Menu {
                                ForEach(syncAndAI.typeSafeModels) { item in
                                    Button(item.name) {
                                        draftTypeSafeConfig.model = item.name
                                        persistTypeSafeConfigIfReady()
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                        }
                    }
                }

                Divider()

                settingsRow(
                    title: "低置信度自动外扩防切边",
                    subtitle: "当 Box 置信度低于 \(Int((draftTypeSafeConfig.minConfidence * 100).rounded()))% 时，四边自动外扩 \(Int((draftTypeSafeConfig.lowConfidencePadding * 100).rounded()))%"
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $draftTypeSafeConfig.minConfidence, in: 0.30...0.90, step: 0.05)
                            .frame(width: 136)
                            .onChange(of: draftTypeSafeConfig.minConfidence) { _, _ in
                                persistTypeSafeConfigIfReady()
                            }
                        Text("\(Int((draftTypeSafeConfig.minConfidence * 100).rounded()))%")
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                Divider()

                DisclosureGroup(isExpanded: $showTypeSafeAdvanced) {
                    VStack(spacing: 10) {
                        settingsRow(title: "服务地址", subtitle: "默认 https://api.typesafe.ai") {
                            TextField("https://api.typesafe.ai", text: $draftTypeSafeConfig.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 230)
                                .onSubmit { persistTypeSafeConfigIfReady() }
                        }
                        settingsRow(
                            title: "情绪板语义局部裁切",
                            subtitle: "支持右键「聚焦主体」「一句话语义裁切」非破坏性写入局部框"
                        ) {
                            Toggle("", isOn: $draftTypeSafeConfig.enableMoodboardFocusCrop)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: draftTypeSafeConfig.enableMoodboardFocusCrop) { _, _ in persistTypeSafeConfigIfReady() }
                        }
                        settingsRow(
                            title: "截图与网页自动去噪裁净",
                            subtitle: "自动识别浏览器外壳、状态栏与多余白边并裁净核心作品"
                        ) {
                            Toggle("", isOn: $draftTypeSafeConfig.enableAutoCleanCrop)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: draftTypeSafeConfig.enableAutoCleanCrop) { _, _ in persistTypeSafeConfigIfReady() }
                        }
                        settingsRow(
                            title: "主体级色板提取与指物批注",
                            subtitle: "过滤背景干扰色提取主体色卡，并将批注箭头精准指向图内物体"
                        ) {
                            Toggle("", isOn: $draftTypeSafeConfig.enableSubjectPalette)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: draftTypeSafeConfig.enableSubjectPalette) { _, _ in
                                    draftTypeSafeConfig.enablePinpointAnnotations = draftTypeSafeConfig.enableSubjectPalette
                                    persistTypeSafeConfigIfReady()
                                }
                        }
                        settingsRow(
                            title: "混合视觉语义搜索",
                            subtitle: "在顶部搜索栏按自然语言直接看图检索，未打标图片也能按氛围与画面命中"
                        ) {
                            Toggle("", isOn: $draftTypeSafeConfig.enableSemanticSearch)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: draftTypeSafeConfig.enableSemanticSearch) { _, _ in persistTypeSafeConfigIfReady() }
                        }
                        settingsRow(
                            title: "收件箱零幻觉智能分拣",
                            subtitle: "用封闭 Choice + 伴随 Noul 将待整理素材精准推荐到已有文件夹"
                        ) {
                            Toggle("", isOn: $draftTypeSafeConfig.enableInboxSmartTriage)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: draftTypeSafeConfig.enableInboxSmartTriage) { _, _ in persistTypeSafeConfigIfReady() }
                        }
                        settingsRow(
                            title: "情绪板策展视觉精排",
                            subtitle: "用 Jev Score 精排候选池，并支持灵感词生板「细节特写模式」"
                        ) {
                            Toggle("", isOn: $draftTypeSafeConfig.enableCuratorVisualRerank)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .onChange(of: draftTypeSafeConfig.enableCuratorVisualRerank) { _, _ in persistTypeSafeConfigIfReady() }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("实验功能开关与高级参数")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var chatGPTSubscriptionSection: some View {
        let session = syncAndAI.chatGPTSession
        VStack(alignment: .leading, spacing: 12) {
            if session.status == .connected {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                            .frame(width: 38, height: 38)
                        chatGPTBrandMark(size: 20, color: .primary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(session.displayName)
                                .font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(1)
                            Circle()
                                .fill(session.sharingEnabled ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(session.sharingEnabled ? "ChatGPT 订阅" : "未开启额度共享")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(session.sharingEnabled ? Color.green : Color.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (session.sharingEnabled ? Color.green : Color.orange).opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        Text(
                            session.email ?? (session.sharingEnabled
                                ? "已通过 Sign in with ChatGPT 连接，直接使用你的订阅额度"
                                : "已登录但未授予额度共享权限，请重新授权")
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    if !session.sharingEnabled {
                        Button("授权额度共享") {
                            Task {
                                if await syncAndAI.signInWithChatGPT(reconsent: true, switchAccount: false) {
                                    draftAIConfig = syncAndAI.aiConfig
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(syncAndAI.isSigningInChatGPT)
                    } else {
                        Button {
                            NSWorkspace.shared.open(ChatGPTSignInClient.usageSettingsURL)
                        } label: {
                            HStack(spacing: 4) {
                                Text("管理用量")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    }

                    Menu {
                        Button("刷新可用模型列表") {
                            Task { await syncAndAI.refreshChatGPTModels(quiet: false) }
                        }
                        Button("在浏览器中管理 ChatGPT 用量…") {
                            NSWorkspace.shared.open(ChatGPTSignInClient.usageSettingsURL)
                        }
                        Divider()
                        Button("切换其他 ChatGPT 账号…") {
                            Task {
                                if await syncAndAI.signInWithChatGPT(reconsent: false, switchAccount: true) {
                                    draftAIConfig = syncAndAI.aiConfig
                                }
                            }
                        }
                        Button("退出 ChatGPT 登录", role: .destructive) {
                            Task { await syncAndAI.disconnectChatGPT(resetRegistration: false) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.vertical, 2)

                if session.sharingEnabled {
                    Divider()

                    settingsRow(
                        title: "理解模型",
                        subtitle: syncAndAI.chatGPTModels.isEmpty
                            ? "将使用所填模型调用 ChatGPT 订阅额度"
                            : "已自动拉取当前 ChatGPT 订阅可用模型（共 \(syncAndAI.chatGPTModels.count) 个）"
                    ) {
                        HStack(spacing: 6) {
                            if !syncAndAI.chatGPTModels.isEmpty {
                                Picker("", selection: $draftAIConfig.chatModel) {
                                    ForEach(syncAndAI.chatGPTModels) { model in
                                        Text(model.displayName).tag(model.slug)
                                    }
                                    if !draftAIConfig.chatModel.isEmpty
                                        && !syncAndAI.chatGPTModels.contains(where: { $0.slug == draftAIConfig.chatModel }) {
                                        Text(draftAIConfig.chatModel).tag(draftAIConfig.chatModel)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 204)
                                .onChange(of: draftAIConfig.chatModel) { _, _ in
                                    persistAIConfigIfReady()
                                }
                            } else {
                                TextField("gpt-5.4-mini", text: $draftAIConfig.chatModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 204)
                                    .onSubmit { persistAIConfigIfReady() }
                            }

                            Button {
                                Task { await syncAndAI.refreshChatGPTModels(quiet: false) }
                            } label: {
                                if syncAndAI.isLoadingChatGPTModels {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11.5))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .fixedSize()
                            .help("刷新 ChatGPT 可用模型列表")
                            .disabled(syncAndAI.isLoadingChatGPTModels)
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                            .frame(width: 38, height: 38)
                        chatGPTBrandMark(size: 20, color: .primary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.status == .reauthRequired ? "ChatGPT 登录已过期" : "使用你的 ChatGPT 订阅额度")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(
                            session.status == .reauthRequired
                                ? "请重新登录以恢复通过 ChatGPT 订阅驱动云端增强智能。"
                                : "无需申请或配置 API 密钥，基于官方 Sign in with ChatGPT 协议直接登录（支持 Plus / Pro 等订阅），凭证仅加密保存在本机钥匙串。"
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    Button {
                        Task {
                            if await syncAndAI.signInWithChatGPT(reconsent: false, switchAccount: false) {
                                draftAIConfig = syncAndAI.aiConfig
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if syncAndAI.isSigningInChatGPT {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(colorScheme == .dark ? .black : .white)
                            } else {
                                chatGPTBrandMark(size: 15, color: colorScheme == .dark ? .black : .white)
                            }
                            Text(syncAndAI.isSigningInChatGPT ? "等待浏览器授权…" : "使用 ChatGPT 登录")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            colorScheme == .dark ? Color.white : Color.black,
                            in: Capsule(style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(syncAndAI.isSigningInChatGPT)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func chatGPTBrandMark(size: CGFloat, color: Color) -> some View {
        let url = Bundle.module.url(forResource: "chatgpt-mark", withExtension: "svg")
            ?? Bundle.module.url(forResource: "chatgpt-mark", withExtension: "svg", subdirectory: "Icons")
        if let url, let nsImage = NSImage(contentsOf: url) {
            let _ = { nsImage.isTemplate = true }()
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(color)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }

    // MARK: - Tab 3: 缓存空间

    private var storagePane: some View {
        let stats = syncAndAI.cacheStats
        let totalUsed = stats.thumbnailBytes + stats.originalCacheBytes + stats.pinnedOfflineBytes
        let barScale = max(Int64(1), max(totalUsed, stats.budgetBytes))

        return VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "缓存空间",
                subtitle: "预览图常驻本机让画廊随时秒开，原始大文件按需缓存；设为「始终保留在本地」的情绪板和素材不会被自动清理。"
            )

            settingsGroupCard {
                HStack(alignment: .firstTextBaseline) {
                    Text("本机已使用缓存")
                        .font(.system(size: 12.5, weight: .semibold))
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
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .frame(height: 18)

                HStack(spacing: 22) {
                    legendDot(color: Color(charkleHex: "#4E7D96"), title: "画廊预览图", bytes: stats.thumbnailBytes)
                    legendDot(color: Color(charkleHex: "#D4A373"), title: "临时原件缓存（\(stats.cachedOriginalCount) 项）", bytes: stats.originalCacheBytes)
                    legendDot(color: Color(charkleHex: "#6B8E76"), title: "始终保留在本地（\(stats.pinnedAssetCount) 项）", bytes: stats.pinnedOfflineBytes)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("临时缓存空间上限")
                            .font(.system(size: 12.5, weight: .medium))
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

                Divider()

                settingsRow(
                    title: "清理临时原件缓存",
                    subtitle: "仅释放未设为常驻的本地缓存，云端原件和「始终保留在本地」的内容不受影响"
                ) {
                    Button("立即清理") {
                        Task { await syncAndAI.evictCacheNow() }
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(syncAndAI.isBusy)
                }
            }
        }
    }

    // MARK: - Tab 4: 采集与快捷键

    private var captureAndShortcutsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "采集与快捷键",
                subtitle: "无论正在浏览网页还是做设计，都能一秒把灵感收入收件箱或当前活跃情绪板。"
            )

            settingsGroupCard {
                settingsRow(
                    title: "屏幕顶部灵感浮窗",
                    subtitle: "在其他应用中拖起图片或文件时，顶部自动滑出收纳区"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.notchShelfEnabled },
                        set: { coordinator.notchShelfEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider()

                settingsRow(
                    title: "悬停顶部中央自动展开",
                    subtitle: "鼠标移至屏幕顶部刘海区域时唤出浮窗"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.notchHoverTriggerEnabled },
                        set: { coordinator.notchHoverTriggerEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!coordinator.notchShelfEnabled)
                }

                Divider()

                settingsRow(
                    title: "启用系统全局快捷键",
                    subtitle: "在任意应用中通过快捷键截图或收藏剪贴板"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.globalHotkeysEnabled },
                        set: { newVal in
                            coordinator.globalHotkeysEnabled = newVal
                            onSyncHotkeysEnabled(newVal)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider()

                HStack {
                    Text("想看看顶部浮窗的效果？")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("预览顶部浮窗") {
                        onToggleNotchPreview()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            settingsGroupCard {
                Text("常用快捷键")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    shortcutRow("⌥ ⇧ A", "区域截图并收入目标")
                    shortcutRow("⌥ ⇧ V", "一键收藏当前剪贴板（含 X 推文与媒体）")
                    shortcutRow("⌥ ⇧ S", "展开 / 收起顶部灵感浮窗")
                    Divider()
                    shortcutRow("Space", "快速预览素材 / 再按一次退出预览")
                    shortcutRow("⌘ C / ⌘ X / ⌘ V", "拷贝、剪切与粘贴移动素材")
                    shortcutRow("⌘ J", "快速跳转情绪板、文件夹或素材")
                    shortcutRow("⌘ N", "快速生成新情绪板")
                    shortcutRow("⇧ ⌘ S", "展开 / 收起视觉与配色筛选条")
                    shortcutRow("1 – 9", "收件箱中快速归档到对应文件夹")
                    Divider()
                    shortcutRow("R / ⇧ R", "情绪板图片顺时针 / 逆时针旋转 90°")
                    shortcutRow("⇧ H / ⇧ V", "情绪板图片水平 / 上下翻转")
                    shortcutRow("鼠标中键拖拽", "情绪板画布自由移动查看")
                    shortcutRow("⌘ Z / ⇧ ⌘ Z", "情绪板撤销 / 重做")
                }
            }
        }
    }

    // MARK: - Smart Defaults & Helpers

    private func applySmartAIDefaults(for provider: CloudAIProviderKind, format: CustomAIEndpointFormat) {
        let knownDefaultURLs: Set<String> = [
            "",
            "https://generativelanguage.googleapis.com",
            "https://api.openai.com",
            "https://api.openai.com/v1",
            "https://api.anthropic.com"
        ]
        let knownDefaultChats: Set<String> = [
            "", "gemini-2.5-flash", "gpt-4.1-mini", "gpt-5.4-mini", "claude-sonnet-4-5"
        ]
        let knownDefaultEmbeddings: Set<String> = [
            "", "gemini-embedding-001", "text-embedding-3-small"
        ]

        switch provider {
        case .disabled:
            break
        case .chatGPTSubscription:
            draftAIConfig.baseURL = ChatGPTSignInClient.resource
            if knownDefaultChats.contains(draftAIConfig.chatModel) {
                draftAIConfig.chatModel = syncAndAI.chatGPTModels.first?.slug ?? "gpt-5.4-mini"
            }
            draftAIConfig.embeddingModel = ""
        case .gemini:
            if knownDefaultURLs.contains(draftAIConfig.baseURL) {
                draftAIConfig.baseURL = "https://generativelanguage.googleapis.com"
            }
            if knownDefaultChats.contains(draftAIConfig.chatModel) {
                draftAIConfig.chatModel = "gemini-2.5-flash"
            }
            if knownDefaultEmbeddings.contains(draftAIConfig.embeddingModel) {
                draftAIConfig.embeddingModel = "gemini-embedding-001"
            }
        case .openAICompatible:
            if knownDefaultURLs.contains(draftAIConfig.baseURL) {
                draftAIConfig.baseURL = format.defaultBaseURL
            }
            if knownDefaultChats.contains(draftAIConfig.chatModel) {
                draftAIConfig.chatModel = format.defaultChatModel
            }
            if knownDefaultEmbeddings.contains(draftAIConfig.embeddingModel) {
                draftAIConfig.embeddingModel = format.defaultEmbeddingModel
            }
        }
    }

    private func endpointFormatSubtitle(_ format: CustomAIEndpointFormat) -> String {
        switch format {
        case .openAIChatCompletions: "标准 /v1/chat/completions（适配 OpenAI、DeepSeek、OpenRouter、Ollama 等）"
        case .anthropicMessages: "标准 /v1/messages（适配 Anthropic Claude 及兼容代理）"
        case .openAIResponses: "新版 /v1/responses（适配 OpenAI Responses 多模态接口）"
        }
    }

    private func storageModeDescription(_ mode: DriveTransportMode) -> String {
        switch mode {
        case .directAPIWithGDirect:
            "通过 Google Drive 直连 API 自动同步（支持本机 gdirect 自动兜底）"
        case .gdirectMount:
            "通过本机 gdirect 挂载读写 Google Drive（可与直连 API 模式共存切换）"
        case .webDAV:
            "连接坚果云、Nextcloud、群晖 NAS 或任意自建 WebDAV 云盘"
        case .localOnly:
            "完全保存在本机指定文件夹，零联网、随时可在访达直接浏览"
        }
    }

    private func googleHeroSubtitle(account: DriveAccountInfo?, isUsingLocalGDirect: Bool) -> String {
        guard account != nil else {
            return "登录 Google 账号后，素材与情绪板将通过 HTTP/2 自动直连同步"
        }
        let prefix = isUsingLocalGDirect ? "当前暂用本机 gdirect 兜底" : "已通过 Google Drive 直连"
        if let synced = syncAndAI.syncStatus.lastSyncedAt {
            return "\(prefix) · 上次同步 \(synced.formatted(date: .omitted, time: .shortened))"
        }
        return "\(prefix) · 点击右侧即可立即同步"
    }

    private func persistSyncConfigIfReady() {
        guard didLoadInitial else { return }
        let snapshot = draftSyncConfig
        Task { await syncAndAI.saveSyncConfig(snapshot, quiet: true) }
    }

    private func persistAIConfigIfReady() {
        guard didLoadInitial else { return }
        let snapshot = draftAIConfig
        Task { await syncAndAI.saveAIConfig(snapshot, apiKey: nil, quiet: true) }
    }

    private func persistTypeSafeConfigIfReady() {
        guard didLoadInitial else { return }
        let snapshot = draftTypeSafeConfig
        Task { await syncAndAI.saveTypeSafeConfig(snapshot, apiKey: nil, quiet: true) }
    }

    // MARK: - Tab 3: 外部 Agent 与 MCP (原生 stdio MCP Server + 命令行工具)

    private var externalAgentPane: some View {
        let helperPath = syncAndAI.resolvedHelperCLIPath()
        let claudeCodeCmd = "claude mcp add charkle -- \"\(helperPath)\" mcp"
        let jsonConfig = """
        {
          "mcpServers": {
            "charkle": {
              "command": "\(helperPath)",
              "args": ["mcp"]
            }
          }
        }
        """

        let enabledBinding = Binding<Bool>(
            get: { draftExternalAgentConfig.enabled },
            set: { newValue in
                draftExternalAgentConfig.enabled = newValue
                syncAndAI.saveExternalAgentConfig(draftExternalAgentConfig)
            }
        )
        let accessBinding = Binding<ExternalAgentAccessLevel>(
            get: { draftExternalAgentConfig.accessLevel },
            set: { newLevel in
                draftExternalAgentConfig.accessLevel = newLevel
                syncAndAI.saveExternalAgentConfig(draftExternalAgentConfig)
            }
        )

        return VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "外部 Agent 与 MCP",
                subtitle: "让 Claude Code、Cursor、Codex、Antigravity 等外部 AI 助手直接检索你的视觉素材库、查看联系表与情绪板，并实时同步更新画布。"
            )

            // Access & Safety Policy
            settingsGroupCard {
                settingsRow(
                    title: "允许外部 AI Agent 接入",
                    subtitle: "内置原生 Swift 助手程序（零 Node/Python 依赖），仅限本机调用，切换设置即时生效"
                ) {
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if draftExternalAgentConfig.enabled {
                    Divider()

                    settingsRow(
                        title: "外部 Agent 权限级别",
                        subtitle: draftExternalAgentConfig.accessLevel.summary
                    ) {
                        Picker("", selection: accessBinding) {
                            Text("仅只读").tag(ExternalAgentAccessLevel.readOnly)
                            Text("允许整理与生板").tag(ExternalAgentAccessLevel.readWriteOrganize)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 224)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                            .padding(.top, 1)
                        Text("安全边界：仅通过本机标准输入输出通信，不开放任何网络端口；外部 Agent 永远无法执行彻底删除，所有删除操作均仅移入回收站。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // Quick Connect Setup
            settingsGroupCard {
                Text("快速接入配置")
                    .font(.system(size: 12.5, weight: .semibold))

                // Claude Code 1-line command
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Claude Code（终端一行添加）")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Button {
                            copyToClipboard(claudeCodeCmd, toast: "已复制 Claude Code 接入命令")
                        } label: {
                            Label("一键复制命令", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text(claudeCodeCmd)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                Divider()

                // Cursor / Antigravity / Codex JSON config
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Cursor / Antigravity / Codex（MCP JSON 配置）")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Button {
                            copyToClipboard(jsonConfig, toast: "已复制 MCP JSON 配置")
                        } label: {
                            Label("复制 JSON 配置", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text(jsonConfig)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                Divider()

                // Terminal CLI Helper
                settingsRow(
                    title: "命令行工具（charkle CLI）",
                    subtitle: "支持脚本、Skill 与非 MCP 代理调用，例如 charkle search / contact-sheet / board export --json"
                ) {
                    HStack(spacing: 6) {
                        Button("复制路径") {
                            copyToClipboard(helperPath, toast: "已复制 charkle 命令行路径")
                        }
                        .controlSize(.small)

                        Button("链接到 ~/.local/bin") {
                            syncAndAI.installCLIInLocalBin()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            // Capabilities Summary Grid
            settingsGroupCard {
                Text("已开放的外部 Agent 能力")
                    .font(.system(size: 12.5, weight: .semibold))

                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        capabilityTile(
                            icon: "photo.on.rectangle.angled",
                            title: "视觉联系表看图",
                            detail: "单次返回带编号的缩略图拼版与清单，让外部 AI 直接看图挑选素材",
                            minHeight: 72
                        )
                        capabilityTile(
                            icon: "swatchpalette.fill",
                            title: "读取情绪板与色板",
                            detail: "导出结构化分区、批注、主色 HEX 与高清图，无缝衔接设计或开发",
                            minHeight: 72
                        )
                    }
                    GridRow {
                        capabilityTile(
                            icon: "folder.badge.gearshape",
                            title: "整理归类与生成画布",
                            detail: "开启写入权限后，可批量打标、整理收件箱、导入素材并创建情绪板",
                            minHeight: 72
                        )
                        capabilityTile(
                            icon: "bolt.horizontal.circle.fill",
                            title: "画布实时热刷新",
                            detail: "外部 Agent 完成整理或生成情绪板后，当前 Charkle 窗口即时更新",
                            minHeight: 72
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyToClipboard(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        syncAndAI.errorMessage = nil
        syncAndAI.statusMessage = toast
    }

    // MARK: - Clean Reusable Product Settings Chrome

    private func settingsHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsGroupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CharkleTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    private func settingsRow<Control: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }

    private func capabilityTile(icon: String, title: String, detail: String, minHeight: CGFloat? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func legendDot(color: Color, title: String, bytes: Int64) -> some View {
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

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack {
            Text(desc)
                .font(.system(size: 12))
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func feedbackBanner(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                if isError { syncAndAI.errorMessage = nil } else { syncAndAI.statusMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background((isError ? Color.red : Color.green).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func pickLocalDirectory(initialPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择素材库保存文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let expanded = (initialPath as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func presentOAuthSecretImporter(autoSignInAfterImport: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = "选择 Google 登录凭据文件 (.json)"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let ok = await syncAndAI.importGoogleOAuthSecret(from: url)
                if ok && autoSignInAfterImport {
                    showOAuthSetupSheet = false
                    _ = await syncAndAI.signInGoogleDrive()
                }
            }
        }
    }
}

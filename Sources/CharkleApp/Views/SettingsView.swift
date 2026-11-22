import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Product-grade macOS Settings window designed around user intent:
/// plain human language, instant auto-save on toggles/pickers, calm visual hierarchy,
/// and technical diagnostics cleanly tucked inside collapsible disclosure sections.
public struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case cloudSync
        case intelligence
        case storage
        case captureShortcuts

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .cloudSync: "云同步"
            case .intelligence: "智能与搜索"
            case .storage: "存储空间"
            case .captureShortcuts: "采集与快捷键"
            }
        }

        public var icon: String {
            switch self {
            case .cloudSync: "drive-sync"
            case .intelligence: "sparkle-board"
            case .storage: "library"
            case .captureShortcuts: "notch"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .cloudSync
    @State private var draftSyncConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var draftAIConfig: AIProviderConfig = AIProviderConfig()
    @State private var apiKeyInput: String = ""
    @State private var cacheBudgetGB: Double = 10.0
    @State private var didLoadInitial: Bool = false

    @State private var showSyncAdvanced: Bool = false
    @State private var showAIAdvanced: Bool = false
    @State private var showOAuthSetupSheet: Bool = false
    @State private var oauthClientIDInput: String = ""
    @State private var oauthClientSecretInput: String = ""

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
                    CharkleIcon("moodboard", style: .layered, size: 22)
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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    if let status = syncAndAI.statusMessage {
                        feedbackBanner(status, isError: false)
                    }
                    if let err = syncAndAI.errorMessage {
                        feedbackBanner(err, isError: true)
                    }

                    switch selectedTab {
                    case .cloudSync:
                        cloudSyncPane
                    case .intelligence:
                        intelligencePane
                    case .storage:
                        storagePane
                    case .captureShortcuts:
                        captureAndShortcutsPane
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CharkleTheme.galleryGround(for: colorScheme))
        }
        .frame(width: 740, height: 600)
        .task {
            await syncAndAI.loadAll()
            draftSyncConfig = syncAndAI.syncConfig
            draftAIConfig = syncAndAI.aiConfig
            cacheBudgetGB = max(2, min(100, Double(syncAndAI.cacheStats.budgetBytes) / (1024 * 1024 * 1024)))
            didLoadInitial = true
        }
        .sheet(isPresented: $showOAuthSetupSheet) {
            googleOAuthSetupSheet
        }
    }

    // MARK: - Tab 1: 云同步

    private var cloudSyncPane: some View {
        let snap = syncAndAI.gdirectSnapshot
        let signedInAccount = syncAndAI.syncStatus.account
        let isSignedIn = signedInAccount != nil
        let isSyncEnabled = draftSyncConfig.mode != .localOnly
        let healthyNodeCount = snap.endpoints.filter(\.healthy).count

        return VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "云同步",
                subtitle: "直接登录你的 Google 账号即可自动备份素材库与情绪板到 Google Drive，无需安装第三方工具。"
            )

            // Account & Primary Sync Status Card
            settingsGroupCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(isSignedIn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                            .frame(width: 44, height: 44)
                        Image(systemName: isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(isSignedIn ? Color.accentColor : .secondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(signedInAccount?.displayName ?? signedInAccount?.email ?? "Google Drive")
                                .font(.system(size: 13.5, weight: .semibold))
                            if isSignedIn {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                            }
                        }

                        if let account = signedInAccount, let name = account.displayName, !name.isEmpty {
                            Text(account.email)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Text(syncHeroSubtitle(account: signedInAccount, isSyncEnabled: isSyncEnabled))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isSignedIn {
                        HStack(spacing: 8) {
                            if isSyncEnabled {
                                Button {
                                    Task { _ = await syncAndAI.syncNow() }
                                } label: {
                                    HStack(spacing: 5) {
                                        if syncAndAI.isBusy {
                                            ProgressView().controlSize(.mini)
                                        }
                                        Text("立即同步")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(syncAndAI.isBusy)
                            }

                            Menu {
                                Button("切换 Google 账号…") {
                                    triggerGoogleSignIn()
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
                            .help("账号操作")
                        }
                    } else {
                        Button {
                            triggerGoogleSignIn()
                        } label: {
                            HStack(spacing: 6) {
                                if syncAndAI.isBusy {
                                    ProgressView().controlSize(.mini)
                                }
                                Text("使用 Google 账号登录")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(syncAndAI.isBusy)
                    }
                }
                .padding(.vertical, 2)

                if let used = signedInAccount?.storageUsedBytes,
                   let limit = signedInAccount?.storageLimitBytes, limit > 0 {
                    Divider()
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
            }

            // Everyday Sync Preferences (instant auto-save)
            settingsGroupCard {
                settingsRow(
                    title: "开启 Google Drive 自动同步",
                    subtitle: isSyncEnabled
                        ? "新增素材、文件夹与情绪板会自动备份到你的 Google Drive"
                        : "当前仅保存在这台 Mac 本地，不联网同步"
                ) {
                    Toggle("", isOn: Binding(
                        get: { draftSyncConfig.mode != .localOnly },
                        set: { enabled in
                            draftSyncConfig.mode = enabled ? .directAPIWithGDirect : .localOnly
                            persistSyncConfigIfReady()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if isSyncEnabled {
                    Divider()

                    settingsRow(
                        title: "云端主文件夹",
                        subtitle: "在 Google Drive 网页版中也能直接浏览这些原文件"
                    ) {
                        TextField("Charkle", text: $draftSyncConfig.rootFolderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 156)
                            .onSubmit { persistSyncConfigIfReady() }
                    }

                    Divider()

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

            // Collapsible Advanced Options (cleanly tucked away for developers & power users)
            settingsGroupCard {
                DisclosureGroup(isExpanded: $showSyncAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().padding(.top, 4)

                        settingsRow(
                            title: "Google 登录应用凭据",
                            subtitle: syncAndAI.hasGoogleOAuthClient
                                ? "已配置，可直接点击上方「使用 Google 账号登录」"
                                : "当前开发版未内置凭据，点击右侧粘贴或导入一次即可使用"
                        ) {
                            Button(syncAndAI.hasGoogleOAuthClient ? "更换凭据…" : "配置凭据…") {
                                showOAuthSetupSheet = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if snap.cliPath != nil {
                            Divider()

                            settingsRow(
                                title: "本机网络直连加速（可选）",
                                subtitle: healthyNodeCount > 0
                                    ? "检测到本机加速工具，当前有 \(healthyNodeCount) 条可用直连线路"
                                    : "无需手动配置，检测到本机直连线路时自动择优提速"
                            ) {
                                Toggle("", isOn: $draftSyncConfig.useGDirectIPAcceleration)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .onChange(of: draftSyncConfig.useGDirectIPAcceleration) { _, _ in persistSyncConfigIfReady() }
                            }

                            HStack(spacing: 8) {
                                Button("重新测速优选") {
                                    Task { await syncAndAI.runGDirectScan() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("刷新线路状态") {
                                    Task { await syncAndAI.probeGDirect() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Spacer()
                            }
                            .disabled(syncAndAI.isBusy)
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

    private var googleOAuthSetupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("配置 Google 登录凭据")
                        .font(.system(size: 15, weight: .semibold))
                    Text("配置一次后即可在 Charkle 内一键登录任意 Google 账号，无需安装 gdirect。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
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

            HStack(spacing: 8) {
                Button {
                    presentOAuthSecretImporter(autoSignInAfterImport: true)
                } label: {
                    Label("从 client_secret.json 文件导入…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            Text("提示：正式发布打包时，将凭据文件放到项目目录 Resources/GoogleOAuthClient.json，终端用户打开 App 即可零配置一键登录 Google。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
        .frame(width: 480)
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
                subtitle: "日常配色筛选、文字识别与相似推荐完全在你的 Mac 本机离线运行，零隐私外传；需要更深语义理解时可按需开启云端增强。"
            )

            // Built-in Offline Capabilities (human benefits, no algorithm names)
            settingsGroupCard {
                Text("本机内置智能（始终免费 · 离线可用）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 10) {
                    capabilityTile(icon: "paintpalette", title: "自动配色提取", detail: "按画面主色调筛选与生成和谐色卡")
                    capabilityTile(icon: "sparkles.rectangle.stack", title: "视觉相似推荐", detail: "离线发现构图与风格接近的参考素材")
                    capabilityTile(icon: "text.viewfinder", title: "图内文字识别", detail: "自动识别中英文海报、截图中的文字")
                    capabilityTile(icon: "magnifyingglass", title: "中文与拼音快搜", detail: "按关键词或拼音首字母秒搜任意灵感")
                }
            }

            // Optional Cloud AI Enhancement
            settingsGroupCard {
                settingsRow(
                    title: "云端语义增强",
                    subtitle: "自动生成画面描述与建议标签，让灵感词生板更懂你的想法"
                ) {
                    Picker("", selection: $draftAIConfig.provider) {
                        Text("关闭（仅本机）").tag(CloudAIProviderKind.disabled)
                        Text("Google Gemini").tag(CloudAIProviderKind.gemini)
                        Text("自定义兼容服务").tag(CloudAIProviderKind.openAICompatible)
                    }
                    .labelsHidden()
                    .frame(width: 176)
                    .onChange(of: draftAIConfig.provider) { _, newProvider in
                        if newProvider == .gemini && draftAIConfig.baseURL.isEmpty {
                            draftAIConfig.baseURL = "https://generativelanguage.googleapis.com"
                        }
                        Task {
                            await syncAndAI.refreshAIKeyPresence(for: newProvider)
                            if didLoadInitial && newProvider == .disabled {
                                await syncAndAI.saveAIConfig(draftAIConfig, apiKey: nil)
                            }
                        }
                    }
                }

                if draftAIConfig.provider != .disabled {
                    Divider()

                    settingsRow(
                        title: "API 密钥",
                        subtitle: syncAndAI.hasStoredAIKey
                            ? "已安全保存在 macOS 钥匙串中"
                            : "密钥仅存于本机钥匙串，绝不上传"
                    ) {
                        HStack(spacing: 6) {
                            SecureField(syncAndAI.hasStoredAIKey ? "••••••••（留空不变）" : "粘贴密钥…", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                            Button("保存") {
                                let keyToSave = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                Task {
                                    await syncAndAI.saveAIConfig(draftAIConfig, apiKey: keyToSave.isEmpty ? nil : keyToSave)
                                    apiKeyInput = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
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
        }
    }

    // MARK: - Tab 3: 存储空间

    private var storagePane: some View {
        let stats = syncAndAI.cacheStats
        let totalUsed = stats.thumbnailBytes + stats.originalCacheBytes + stats.pinnedOfflineBytes
        let barScale = max(Int64(1), max(totalUsed, stats.budgetBytes))

        return VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "存储空间",
                subtitle: "预览图常驻本机让画廊随时秒开，原始大文件按需缓存；设为「始终保留在本地」的情绪板和素材不会被自动清理。"
            )

            settingsGroupCard {
                HStack(alignment: .firstTextBaseline) {
                    Text("本机已使用空间")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: totalUsed, countStyle: .file)) / \(Int(cacheBudgetGB.rounded())) GB 上限")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                // Clean macOS-style segmented storage bar
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
                }
            }

            settingsGroupCard {
                Text("常用快捷键")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    shortcutRow("⌥ ⇧ A", "区域截图并收入目标")
                    shortcutRow("⌥ ⇧ V", "一键收藏当前剪贴板")
                    shortcutRow("⌥ ⇧ S", "展开 / 收起顶部灵感浮窗")
                    Divider()
                    shortcutRow("Space", "快速预览素材（画布中按住拖拽可平移）")
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

    // MARK: - Auto-Save Helpers

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

    private func syncHeroSubtitle(account: DriveAccountInfo?, isSyncEnabled: Bool) -> String {
        guard account != nil else {
            return "登录 Google 账号后，素材与情绪板将自动安全备份到你的云盘"
        }
        if !isSyncEnabled {
            return "已登录 · 当前已暂停自动同步，仅保存在本机"
        }
        if let synced = syncAndAI.syncStatus.lastSyncedAt {
            return "已连接 · 上次同步 \(synced.formatted(date: .omitted, time: .shortened))"
        }
        return "已连接 · 就绪，可随时同步"
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

    private func capabilityTile(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
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

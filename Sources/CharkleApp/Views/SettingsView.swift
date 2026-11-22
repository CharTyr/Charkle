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
    }

    // MARK: - Tab 1: 云同步

    private var cloudSyncPane: some View {
        let snap = syncAndAI.gdirectSnapshot
        let activeAccountEmail = syncAndAI.syncStatus.account?.email
            ?? draftSyncConfig.selectedGDirectAccount
            ?? snap.defaultAccount
            ?? snap.accounts.first
        let isConnected = syncAndAI.syncStatus.account != nil || (draftSyncConfig.mode == .gdirectMount && snap.isMountActive)
        let healthyNodeCount = snap.endpoints.filter(\.healthy).count

        return VStack(alignment: .leading, spacing: 18) {
            settingsHeader(
                title: "云同步",
                subtitle: "将你的素材库和情绪板安全备份到 Google Drive，在多台 Mac 之间自动保持同步。"
            )

            // Account & Primary Sync Status Card
            settingsGroupCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 42, height: 42)
                        Image(systemName: isConnected ? "icloud.fill" : "person.crop.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(activeAccountEmail ?? "未连接 Google Drive")
                                .font(.system(size: 13.5, weight: .semibold))
                            if isConnected {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                            }
                        }

                        Text(syncHeroSubtitle(isConnected: isConnected, healthyNodes: healthyNodeCount, snap: snap))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if draftSyncConfig.mode == .localOnly {
                        Text("仅本机模式")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                    } else if isConnected {
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
                    } else {
                        Button("连接账号") {
                            Task { await syncAndAI.signInGoogleDrive() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(syncAndAI.isBusy)
                    }
                }
                .padding(.vertical, 2)

                if snap.hasVersionMismatch {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("检测到本机直连加速组件版本不一致，建议更新以保证最佳同步速度。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // Everyday Sync Preferences (instant auto-save, no "Save Config" developer button)
            settingsGroupCard {
                settingsRow(
                    title: "同步方式",
                    subtitle: syncModeDescription(draftSyncConfig.mode)
                ) {
                    Picker("", selection: $draftSyncConfig.mode) {
                        Text("自动直连（推荐）").tag(DriveTransportMode.directAPIWithGDirect)
                        Text("本地云盘目录").tag(DriveTransportMode.gdirectMount)
                        Text("仅保存在本机").tag(DriveTransportMode.localOnly)
                    }
                    .labelsHidden()
                    .frame(width: 176)
                    .onChange(of: draftSyncConfig.mode) { _, _ in persistSyncConfigIfReady() }
                }

                if draftSyncConfig.mode != .localOnly {
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

                    if draftSyncConfig.mode == .gdirectMount {
                        Divider()
                        settingsRow(
                            title: "本机云盘位置",
                            subtitle: snap.isMountActive ? "目录已连接，可直接在访达查看" : "尚未连接，点击右侧一键挂载"
                        ) {
                            HStack(spacing: 6) {
                                TextField("~/GoogleDrive", text: $draftSyncConfig.mountPath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 164)
                                    .onSubmit { persistSyncConfigIfReady() }
                                Button(snap.isMountActive ? "已连接" : "连接目录") {
                                    Task { await syncAndAI.runGDirectMount(path: draftSyncConfig.mountPath) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(syncAndAI.isBusy)
                            }
                        }
                    }

                    Divider()

                    settingsRow(
                        title: "启用直连加速",
                        subtitle: healthyNodeCount > 0
                            ? "已通过本机加速服务自动择优，当前可用 \(healthyNodeCount) 条线路"
                            : "提升大图片与视频的上传和预览加载速度"
                    ) {
                        Toggle("", isOn: $draftSyncConfig.useGDirectIPAcceleration)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: draftSyncConfig.useGDirectIPAcceleration) { _, _ in persistSyncConfigIfReady() }
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

            // Collapsible Advanced & Diagnostics (cleanly hidden by default for regular users)
            settingsGroupCard {
                DisclosureGroup(isExpanded: $showSyncAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider().padding(.top, 4)

                        if snap.accounts.count > 1 {
                            settingsRow(title: "切换本机账号", subtitle: nil) {
                                Picker("", selection: Binding(
                                    get: { draftSyncConfig.selectedGDirectAccount ?? snap.defaultAccount ?? snap.accounts.first ?? "" },
                                    set: {
                                        draftSyncConfig.selectedGDirectAccount = $0
                                        persistSyncConfigIfReady()
                                    }
                                )) {
                                    ForEach(snap.accounts, id: \.self) { acc in
                                        Text(acc).tag(acc)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 210)
                            }
                            Divider()
                        }

                        HStack(spacing: 14) {
                            diagnosticPill("加速组件", snap.cliVersion ?? "未安装", ok: snap.cliPath != nil)
                            diagnosticPill("桌面端", snap.appVersion ?? "未安装", ok: snap.appVersion != nil)
                            diagnosticPill("云盘目录", snap.isMountActive ? "已连接" : "未连接", ok: snap.isMountActive)
                            diagnosticPill("可用线路", "\(healthyNodeCount) 条", ok: healthyNodeCount > 0)
                        }

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

                            Button("导入自定义登录凭据…") {
                                presentOAuthSecretImporter()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer()
                        }
                        .disabled(syncAndAI.isBusy)

                        if !snap.endpoints.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("最快直连线路（前 6 条）")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(snap.endpoints.prefix(6)) { ep in
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(ep.healthy ? Color.green : Color.orange)
                                                .frame(width: 5, height: 5)
                                            Text("\(ep.ip) · \(ep.latencyMs)ms")
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text("高级选项与连接诊断")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
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
                subtitle: "预览图常驻本机让画廊随时秒开，原始大文件按需缓存；你钉选离线的情绪板和素材会永久保留在本机。"
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
                    legendDot(color: Color(charkleHex: "#6B8E76"), title: "钉选离线（\(stats.pinnedAssetCount) 项）", bytes: stats.pinnedOfflineBytes)
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
                    subtitle: "仅释放未钉选的本地缓存，云端原件和情绪板完全不受影响"
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
        Task { await syncAndAI.saveSyncConfig(snapshot) }
    }

    private func persistAIConfigIfReady() {
        guard didLoadInitial else { return }
        let snapshot = draftAIConfig
        Task { await syncAndAI.saveAIConfig(snapshot, apiKey: nil) }
    }

    private func syncHeroSubtitle(isConnected: Bool, healthyNodes: Int, snap: GDirectEnvironmentSnapshot) -> String {
        if draftSyncConfig.mode == .localOnly {
            return "当前仅保存在这台 Mac 本地，不会上传至云端"
        }
        var parts: [String] = []
        if isConnected {
            if let synced = syncAndAI.syncStatus.lastSyncedAt {
                parts.append("上次同步 \(synced.formatted(date: .omitted, time: .shortened))")
            } else {
                parts.append("已就绪，可随时同步")
            }
        } else if snap.accounts.first != nil {
            parts.append("已发现本机账号，点击右侧连接即可开始同步")
        } else {
            parts.append("连接 Google Drive 后即可自动多端备份")
        }
        if draftSyncConfig.useGDirectIPAcceleration && healthyNodes > 0 {
            parts.append("直连加速已开启")
        }
        return parts.joined(separator: " · ")
    }

    private func syncModeDescription(_ mode: DriveTransportMode) -> String {
        switch mode {
        case .directAPIWithGDirect: "直接与 Google Drive 安全同步，无需常驻挂载虚拟磁盘"
        case .gdirectMount: "通过本机已挂载的云盘文件夹读写，访达里同步可见"
        case .localOnly: "完全离线保存在本机，不联网也不上传任何文件"
        }
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

    private func diagnosticPill(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        }
        .padding(10)
        .background((isError ? Color.red : Color.green).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func presentOAuthSecretImporter() {
        let panel = NSOpenPanel()
        panel.title = "选择 Google 登录凭据文件 (.json)"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await syncAndAI.importGoogleOAuthSecret(from: url) }
        }
    }
}

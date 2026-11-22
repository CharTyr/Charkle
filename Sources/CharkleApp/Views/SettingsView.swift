import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Spacious tabbed macOS Settings (`780 × 640`, zero clipped text):
/// 1. Google Drive & `gdirect`
/// 2. AI 智能
/// 3. 存储与缓存
/// 4. 快捷键与刘海浮窗
public struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case driveSync
        case intelligence
        case storageCache
        case hotkeysNotch

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .driveSync: "Google Drive & gdirect"
            case .intelligence: "AI 智能"
            case .storageCache: "存储与缓存"
            case .hotkeysNotch: "快捷键与刘海浮窗"
            }
        }

        public var icon: String {
            switch self {
            case .driveSync: "drive-sync"
            case .intelligence: "sparkle-board"
            case .storageCache: "library"
            case .hotkeysNotch: "notch"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .driveSync
    @State private var draftSyncConfig: DriveSyncConfig = DriveSyncConfig()
    @State private var draftAIConfig: AIProviderConfig = AIProviderConfig()
    @State private var apiKeyInput: String = ""
    @State private var cacheBudgetGB: Double = 10.0

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
            // Left Settings Rail
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    CharkleIcon("settings", style: .layered, size: 22)
                    Text("Charkle 设置")
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
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }

                Spacer()
            }
            .frame(width: 204)
            .background(CharkleTheme.inspectorBackground(for: colorScheme))

            Divider()

            // Right Detail Pane
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    if let status = syncAndAI.statusMessage {
                        feedbackBanner(status, isError: false)
                    }
                    if let err = syncAndAI.errorMessage {
                        feedbackBanner(err, isError: true)
                    }

                    switch selectedTab {
                    case .driveSync:
                        driveAndGDirectPane
                    case .intelligence:
                        intelligencePane
                    case .storageCache:
                        storageAndCachePane
                    case .hotkeysNotch:
                        hotkeysAndNotchPane
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CharkleTheme.galleryGround(for: colorScheme))
        }
        .frame(width: 780, height: 640)
        .task {
            await syncAndAI.loadAll()
            draftSyncConfig = syncAndAI.syncConfig
            draftAIConfig = syncAndAI.aiConfig
            cacheBudgetGB = max(2, min(100, Double(syncAndAI.cacheStats.budgetBytes) / (1024 * 1024 * 1024)))
        }
    }

    // MARK: - Tab 1: Google Drive & gdirect

    private var driveAndGDirectPane: some View {
        let snap = syncAndAI.gdirectSnapshot
        return VStack(alignment: .leading, spacing: 16) {
            settingsHeader(
                title: "Google Drive 与 gdirect 双通道同步",
                subtitle: "以人类可读目录 /Charkle/ 存储原始文件，元数据与情绪板按设备分片增量同步零冲突"
            )

            // Transport Mode Picker
            settingsCard("传输通道模式") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("同步模式", selection: $draftSyncConfig.mode) {
                        ForEach(DriveTransportMode.allCases, id: \.self) { mode in
                            Text(mode.localizedLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    HStack(spacing: 12) {
                        Text("Drive 根目录名")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("Charkle", text: $draftSyncConfig.rootFolderName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)

                        Toggle("启用 gdirect 直连 IP 加速", isOn: $draftSyncConfig.useGDirectIPAcceleration)
                            .font(.system(size: 12))
                    }

                    if draftSyncConfig.mode == .gdirectMount {
                        HStack(spacing: 10) {
                            Text("挂载目录")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            TextField("~/GoogleDrive", text: $draftSyncConfig.mountPath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack(spacing: 16) {
                        Toggle("同步共享缩略图（跨设备秒开）", isOn: $draftSyncConfig.syncThumbnails)
                            .font(.system(size: 12))
                        Toggle("同步向量分片", isOn: $draftSyncConfig.syncEmbeddings)
                            .font(.system(size: 12))
                    }

                    HStack {
                        Spacer()
                        Button("保存通道配置") {
                            Task { await syncAndAI.saveSyncConfig(draftSyncConfig) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            // Live gdirect Environment Card
            settingsCard("本机 gdirect 环境与直连节点") {
                VStack(alignment: .leading, spacing: 12) {
                    if snap.hasVersionMismatch {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("检测到 gdirect CLI (\(snap.cliVersion ?? "未知")) 与 gdirect.app (\(snap.appVersion ?? "未知")) 版本不一致，建议升级 CLI 以获得最新直连加速与挂载稳定性。")
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Status Chips Row (clean wrapping flow layout)
                    CharkleFlowLayout(spacing: 8, lineSpacing: 8) {
                        statusChip(label: "CLI", value: snap.cliVersion ?? "未检测到", ok: snap.cliPath != nil)
                        statusChip(label: "App", value: snap.appVersion ?? "未安装", ok: snap.appVersion != nil)
                        statusChip(label: "rclone", value: snap.rclonePath != nil ? "就绪" : "未检测", ok: snap.rclonePath != nil)
                        statusChip(label: "挂载状态", value: snap.isMountActive ? "已挂载 (st_dev)" : "未挂载", ok: snap.isMountActive)
                    }

                    // Accounts Wrapping Chips
                    if !snap.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("已识别 gdirect 账号")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(snap.accounts, id: \.self) { acc in
                                    let isSelected = draftSyncConfig.selectedGDirectAccount == acc || (draftSyncConfig.selectedGDirectAccount == nil && snap.defaultAccount == acc)
                                    Button {
                                        draftSyncConfig.selectedGDirectAccount = acc
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "person.crop.circle")
                                                .font(.system(size: 11))
                                            Text(acc)
                                                .font(.system(size: 11.5, weight: .medium))
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(
                                            isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                                            in: Capsule(style: .continuous)
                                        )
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Low-Latency Endpoint Wrapping Chips
                    if !snap.endpoints.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("低延迟直连 Google IP 节点 (\(snap.endpoints.count))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(snap.endpoints) { ep in
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(ep.healthy ? Color.green : Color.orange)
                                            .frame(width: 6, height: 6)
                                        Text("\(ep.ip) · \(ep.latencyMs)ms")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .monospacedDigit()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            }
                        }
                    }

                    // Action Buttons Row
                    CharkleFlowLayout(spacing: 8, lineSpacing: 8) {
                        Button("探测环境") { Task { await syncAndAI.probeGDirect() } }
                            .buttonStyle(.bordered)
                        Button("扫描直连 IP") { Task { await syncAndAI.runGDirectScan() } }
                            .buttonStyle(.bordered)
                        Button("执行 gdirect mount") { Task { await syncAndAI.runGDirectMount(path: draftSyncConfig.mountPath) } }
                            .buttonStyle(.bordered)
                        Button("导入 OAuth 凭据…") { presentOAuthSecretImporter() }
                            .buttonStyle(.bordered)
                        Button("登录 Google Drive") { Task { await syncAndAI.signInGoogleDrive() } }
                            .buttonStyle(.bordered)
                        Button("立即同步") { Task { _ = await syncAndAI.syncNow() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(syncAndAI.isBusy)

                    if let account = syncAndAI.syncStatus.account {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("已授权账号：\(account.email)")
                                .font(.system(size: 11.5, weight: .medium))
                            if let synced = syncAndAI.syncStatus.lastSyncedAt {
                                Text("· 上次同步 \(synced.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: AI Intelligence

    private var intelligencePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeader(
                title: "混合智能引擎（端侧常驻 + 云端可选）",
                subtitle: "端侧离线分析默认始终开启且零隐私外传；需要更深语义搜索与双语标签时可按需接入云端模型"
            )

            settingsCard("端侧离线常驻引擎（零配置 · 永久免费）") {
                CharkleFlowLayout(spacing: 8, lineSpacing: 8) {
                    statusChip(label: "色彩", value: "CIELAB 感知色板 & ΔE", ok: true)
                    statusChip(label: "视觉", value: "Apple Vision VNFeaturePrint", ok: true)
                    statusChip(label: "OCR", value: "中英文离线文字识别", ok: true)
                    statusChip(label: "检索", value: "FTS5 中文拼音分词", ok: true)
                }
            }

            settingsCard("可选云端语义增强（密钥仅存于 macOS 钥匙串）") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("云端服务", selection: $draftAIConfig.provider) {
                        ForEach(CloudAIProviderKind.allCases, id: \.self) { kind in
                            Text(kind.localizedLabel).tag(kind)
                        }
                    }
                    .onChange(of: draftAIConfig.provider) { _, newProvider in
                        Task { await syncAndAI.refreshAIKeyPresence(for: newProvider) }
                    }

                    if draftAIConfig.provider != .disabled {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("API Endpoint")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                TextField("https://generativelanguage.googleapis.com", text: $draftAIConfig.baseURL)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("多模态模型")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                TextField("gemini-2.5-flash", text: $draftAIConfig.chatModel)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("向量模型")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                TextField("gemini-embedding-001", text: $draftAIConfig.embeddingModel)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("API Key")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                HStack {
                                    SecureField(syncAndAI.hasStoredAIKey ? "钥匙串已保存密钥（留空保持不变）" : "粘贴 API Key…", text: $apiKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                    if syncAndAI.hasStoredAIKey {
                                        Text("已存入钥匙串")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }

                        Toggle("导入新素材时自动触发云端标签与描述增强", isOn: $draftAIConfig.autoAnalyzeOnImport)
                            .font(.system(size: 12))
                        Toggle("仅发送 520px 低分辨率缩略图（保护原图与流量）", isOn: $draftAIConfig.sendThumbnailsToCloud)
                            .font(.system(size: 12))
                    }

                    HStack {
                        Spacer()
                        Button("保存 AI 配置") {
                            let keyToSave = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await syncAndAI.saveAIConfig(draftAIConfig, apiKey: keyToSave.isEmpty ? nil : keyToSave)
                                apiKeyInput = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    // MARK: - Tab 3: Storage & Two-Tier LRU Cache

    private var storageAndCachePane: some View {
        let stats = syncAndAI.cacheStats
        let totalUsed = max(1, stats.thumbnailBytes + stats.originalCacheBytes + stats.pinnedOfflineBytes)
        let budget = max(totalUsed, stats.budgetBytes)

        return VStack(alignment: .leading, spacing: 16) {
            settingsHeader(
                title: "两级本地缓存与离线保护",
                subtitle: "520px 缩略图常驻本机实现断网秒览；原文件按 LRU 预算自动回收，钉选离线资产永不淘汰"
            )

            settingsCard("本机磁盘占用分布") {
                VStack(alignment: .leading, spacing: 14) {
                    // Stacked visual breakdown bar
                    GeometryReader { geo in
                        let w = max(10, geo.size.width)
                        let thumbW = max(6, w * CGFloat(Double(stats.thumbnailBytes) / Double(budget)))
                        let origW = max(6, w * CGFloat(Double(stats.originalCacheBytes) / Double(budget)))
                        let pinW = max(6, w * CGFloat(Double(stats.pinnedOfflineBytes) / Double(budget)))
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(charkleHex: "#4E7D96"))
                                .frame(width: min(w * 0.45, thumbW))
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(charkleHex: "#D4A373"))
                                .frame(width: min(w * 0.45, origW))
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(charkleHex: "#6B8E76"))
                                .frame(width: min(w * 0.45, pinW))
                            Spacer(minLength: 0)
                        }
                        .padding(3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .frame(height: 18)

                    HStack(spacing: 18) {
                        legendDot(color: Color(charkleHex: "#4E7D96"), title: "缩略图常驻", bytes: stats.thumbnailBytes)
                        legendDot(color: Color(charkleHex: "#D4A373"), title: "原文件 LRU (\(stats.cachedOriginalCount))", bytes: stats.originalCacheBytes)
                        legendDot(color: Color(charkleHex: "#6B8E76"), title: "钉选离线 (\(stats.pinnedAssetCount))", bytes: stats.pinnedOfflineBytes)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("原文件 LRU 缓存上限")
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text("\(Int(cacheBudgetGB.rounded())) GB")
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                        }
                        Slider(value: $cacheBudgetGB, in: 2...100, step: 1) { editing in
                            if !editing {
                                Task { await syncAndAI.setCacheBudgetGB(cacheBudgetGB) }
                            }
                        }
                    }

                    HStack {
                        Text("清理仅释放未钉选的本地原文件缓存，Google Drive 云端原件与情绪板完全不受影响。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("立即清理 LRU 缓存") {
                            Task { await syncAndAI.evictCacheNow() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(syncAndAI.isBusy)
                    }
                }
            }
        }
    }

    // MARK: - Tab 4: Global Hotkeys & MacBook Notch Shelf

    private var hotkeysAndNotchPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeader(
                title: "全局快捷键与 MacBook 刘海浮窗",
                subtitle: "后台零干扰采集：支持跨 App 直接拖入刘海，提前展开规避 Mission Control 切屏"
            )

            settingsCard("刘海浮窗采集行为") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用 MacBook 刘海浮窗（跨 App 拖放自动展开）", isOn: Binding(
                        get: { coordinator.notchShelfEnabled },
                        set: { coordinator.notchShelfEnabled = $0 }
                    ))
                    Toggle("鼠标悬停屏幕顶部刘海区域时自动展开", isOn: Binding(
                        get: { coordinator.notchHoverTriggerEnabled },
                        set: { coordinator.notchHoverTriggerEnabled = $0 }
                    ))
                    .disabled(!coordinator.notchShelfEnabled)

                    Toggle("注册系统全局快捷键（⌥⇧A / ⌥⇧S / ⌥⇧V）", isOn: Binding(
                        get: { coordinator.globalHotkeysEnabled },
                        set: { newVal in
                            coordinator.globalHotkeysEnabled = newVal
                            onSyncHotkeysEnabled(newVal)
                        }
                    ))

                    HStack {
                        Spacer()
                        Button("测试展开 / 收起刘海浮窗") {
                            onToggleNotchPreview()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            settingsCard("快捷键一览") {
                VStack(spacing: 8) {
                    shortcutRow("⌥ ⇧ A", "交互式区域截图并按刘海目标入库")
                    shortcutRow("⌥ ⇧ S", "随时展开 / 收起刘海浮窗")
                    shortcutRow("⌥ ⇧ V", "一键收藏当前剪贴板（图片 / 链接 / 色值 / 文本）")
                    Divider()
                    shortcutRow("Space", "打开 / 关闭全媒体 Quick Look 预览")
                    shortcutRow("⌘ J", "快速跳转任意情绪板、文件夹、标签或素材")
                    shortcutRow("⇧ ⌘ S", "展开 / 收起顶部视觉与 CIELAB 色彩筛选条")
                    shortcutRow("1 – 9", "收件箱清理台：一键归档至前 9 个文件夹")
                    shortcutRow("⌘ Z / ⇧ ⌘ Z", "情绪板画布完整撤销 / 重做")
                    shortcutRow("V / H / C / P / E", "自由画布切换 选择 / 抓手 / 连线 / 手绘 / 橡皮")
                }
            }
        }
    }

    // MARK: - Reusable Settings Chrome

    private func settingsHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            content()
        }
        .padding(14)
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

    private func statusChip(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous))
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
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background((isError ? Color.red : Color.green).opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func presentOAuthSecretImporter() {
        let panel = NSOpenPanel()
        panel.title = "选择 Google OAuth client_secret.json"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await syncAndAI.importGoogleOAuthSecret(from: url) }
        }
    }
}

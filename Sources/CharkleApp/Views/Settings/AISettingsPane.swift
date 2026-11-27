import AppKit
import CharkleCore
import SwiftUI

/// Tab 6: AI 智能 (AI) — Unified AI pane covering built-in offline Apple Vision capabilities,
/// Cloud AI providers (ChatGPT Subscription / Gemini / Custom API with presets & live test),
/// TypeSafe visual enhancement (human-labeled), and compact usage summary with detail sheet.
public struct AISettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource

    public let syncAndAI: SyncAndAIStore

    @State private var draftAIConfig: AIProviderConfig = AIProviderConfig()
    @State private var draftTypeSafeConfig: TypeSafeExperimentalConfig = TypeSafeExperimentalConfig()
    @State private var didLoadDraft: Bool = false

    @State private var showCloudConfigSheet: Bool = false
    @State private var apiKeyInput: String = ""
    @State private var showGeminiAdvanced: Bool = false

    @State private var showTypeSafeSheet: Bool = false
    @State private var typeSafeKeyInput: String = ""
    @State private var showTypeSafeEndpoint: Bool = false

    @State private var showUsageSheet: Bool = false

    private struct CustomEndpointPreset: Identifiable {
        let id: String
        let label: String
        let format: CustomAIEndpointFormat
        let baseURL: String
        let chatModel: String
        let embeddingModel: String
    }

    private static let customPresets: [CustomEndpointPreset] = [
        CustomEndpointPreset(
            id: "openai",
            label: "OpenAI",
            format: .openAIChatCompletions,
            baseURL: "https://api.openai.com/v1",
            chatModel: "gpt-4.1-mini",
            embeddingModel: "text-embedding-3-small"
        ),
        CustomEndpointPreset(
            id: "anthropic",
            label: "Claude",
            format: .anthropicMessages,
            baseURL: "https://api.anthropic.com",
            chatModel: "claude-sonnet-4-5",
            embeddingModel: ""
        ),
        CustomEndpointPreset(
            id: "openrouter",
            label: "OpenRouter",
            format: .openAIChatCompletions,
            baseURL: "https://openrouter.ai/api/v1",
            chatModel: "google/gemini-2.5-flash",
            embeddingModel: ""
        ),
        CustomEndpointPreset(
            id: "deepseek",
            label: "DeepSeek",
            format: .openAIChatCompletions,
            baseURL: "https://api.deepseek.com/v1",
            chatModel: "deepseek-chat",
            embeddingModel: ""
        ),
        CustomEndpointPreset(
            id: "ollama",
            label: "Ollama 本地",
            format: .openAIChatCompletions,
            baseURL: "http://localhost:11434/v1",
            chatModel: "qwen2.5vl:7b",
            embeddingModel: "nomic-embed-text"
        )
    ]

    public init(syncAndAI: SyncAndAIStore) {
        self.syncAndAI = syncAndAI
    }

    private var isCloudProviderReady: Bool {
        switch draftAIConfig.provider {
        case .disabled:
            return false
        case .chatGPTSubscription:
            return syncAndAI.chatGPTSession.status == .connected && syncAndAI.chatGPTSession.sharingEnabled
        case .gemini:
            return syncAndAI.hasStoredAIKey
        case .openAICompatible:
            let hasBase = !draftAIConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isLocalHost = draftAIConfig.baseURL.lowercased().contains("localhost") || draftAIConfig.baseURL.contains("127.0.0.1")
            return hasBase && (syncAndAI.hasStoredAIKey || isLocalHost)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            offlineCapabilitiesSection
            cloudIntelligenceSection
            visualEnhancementSection
            usageSummarySection
        }
        .onAppear {
            draftAIConfig = syncAndAI.aiConfig
            draftTypeSafeConfig = syncAndAI.typeSafeConfig
            didLoadDraft = true
        }
        .onChange(of: syncAndAI.aiConfig) { _, latest in
            draftAIConfig = latest
        }
        .onChange(of: syncAndAI.typeSafeConfig) { _, latest in
            draftTypeSafeConfig = latest
        }
        .sheet(isPresented: $showCloudConfigSheet) {
            cloudAIConfigSheet
        }
        .onChange(of: showCloudConfigSheet) { wasOpen, isOpen in
            if isOpen {
                syncAndAI.errorMessage = nil
                syncAndAI.statusMessage = nil
            } else if wasOpen {
                draftAIConfig = syncAndAI.aiConfig
                apiKeyInput = ""
            }
        }
        .sheet(isPresented: $showTypeSafeSheet) {
            typeSafeConfigSheet
        }
        .onChange(of: showTypeSafeSheet) { wasOpen, isOpen in
            if isOpen {
                syncAndAI.errorMessage = nil
                syncAndAI.statusMessage = nil
            } else if wasOpen {
                draftTypeSafeConfig = syncAndAI.typeSafeConfig
                typeSafeKeyInput = ""
            }
        }
        .sheet(isPresented: $showUsageSheet) {
            usageDetailSheet
        }
    }

    // MARK: - Built-in Offline Capabilities Strip

    private var offlineCapabilitiesSection: some View {
        SettingsSection("基础离线能力", caption: "全部 Mac 免费内置 · 无需下载 · 数据不出本机") {
            HStack(spacing: 0) {
                offlineBadge(icon: "paintpalette", label: "自动配色提取")
                CharkleHairlineDivider(axis: .vertical)
                    .frame(height: 18)
                offlineBadge(icon: "sparkles.rectangle.stack", label: "视觉相似推荐")
                CharkleHairlineDivider(axis: .vertical)
                    .frame(height: 18)
                offlineBadge(icon: "text.viewfinder", label: "图内文字 OCR")
                CharkleHairlineDivider(axis: .vertical)
                    .frame(height: 18)
                offlineBadge(icon: "magnifyingglass", label: "中文与拼音快搜")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
        }
    }

    private func offlineBadge(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SettingsPalette.positiveInk(for: colorScheme))
            Text(label)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 24)
    }

    // MARK: - Cloud AI Section

    private var cloudIntelligenceSection: some View {
        SettingsSection("云端增强智能") {
            if !isCloudProviderReady {
                SettingsRow(
                    title: cloudDisconnectedTitle,
                    subtitle: cloudDisconnectedSubtitle,
                    subtitleColor: draftAIConfig.provider == .disabled ? .secondary : SettingsPalette.warningInk(for: colorScheme)
                ) {
                    HStack(spacing: 8) {
                        Button("Gemini / 自定义 API…") {
                            if draftAIConfig.provider == .disabled || draftAIConfig.provider == .chatGPTSubscription {
                                draftAIConfig.provider = .gemini
                                applySmartAIDefaults(for: .gemini, format: draftAIConfig.customEndpointFormat)
                            }
                            apiKeyInput = ""
                            showCloudConfigSheet = true
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()

                        Button {
                            Task {
                                let reconsent = syncAndAI.chatGPTSession.status == .connected && !syncAndAI.chatGPTSession.sharingEnabled
                                if await syncAndAI.signInWithChatGPT(reconsent: reconsent, switchAccount: false) {
                                    draftAIConfig = syncAndAI.aiConfig
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if syncAndAI.isSigningInChatGPT {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    SettingsHelpers.chatGPTBrandMark(
                                        size: 13.5,
                                        color: CharkleTheme.accentButtonForeground(for: colorScheme, source: accentSource)
                                    )
                                }
                                Text(syncAndAI.isSigningInChatGPT ? "等待授权…" : "使用 ChatGPT 登录")
                            }
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .fixedSize()
                        .disabled(syncAndAI.isSigningInChatGPT)
                    }
                }

                InlineGuideDisclosure("各方案怎么选？如何获取 API 密钥") {
                    SettingsGuideStep(
                        "1",
                        title: "ChatGPT 订阅账号（最省心，零密钥配置）",
                        detail: "已有 ChatGPT Plus / Pro 订阅时直接登录授权，无需申请或管理 API Key。"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "Google Gemini（性价比高，原生支持多模态与向量检索）",
                        detail: "前往 Google AI Studio 免费创建 API Key，点击「Gemini / 自定义 API…」粘贴保存即可。"
                    )
                    SettingsGuideStep(
                        "3",
                        title: "自定义 API（支持 Claude / OpenRouter / DeepSeek / 本机 Ollama）",
                        detail: "内置常见服务商一键预设，也支持连接本机运行的 Ollama 多模态模型。"
                    )
                }
            } else {
                SettingsRow(
                    title: cloudConnectedTitle,
                    subtitle: cloudConnectedSubtitle,
                    subtitleColor: SettingsPalette.positiveInk(for: colorScheme)
                ) {
                    HStack(spacing: 8) {
                        Button {
                            let cfg = draftAIConfig
                            Task { _ = await syncAndAI.testAIConnection(config: cfg, apiKey: nil) }
                        } label: {
                            HStack(spacing: 5) {
                                if syncAndAI.isTestingAI { ProgressView().controlSize(.mini) }
                                Text(syncAndAI.isTestingAI ? "测试中…" : "测试连接")
                            }
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                        .disabled(syncAndAI.isTestingAI)

                        Button("更改配置…") {
                            apiKeyInput = ""
                            showCloudConfigSheet = true
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .fixedSize()
                    }
                }
            }

            if draftAIConfig.provider != .disabled {
                SettingsCardDivider()

                SettingsRow(
                    title: "导入时自动分析",
                    subtitle: "收藏新素材后自动补充画面描述与建议标签，让灵感词生板更懂你的参考库"
                ) {
                    Toggle("", isOn: $draftAIConfig.autoAnalyzeOnImport)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: draftAIConfig.autoAnalyzeOnImport) { _, newVal in
                            persistAIConfigIfReady(message: newVal ? "已开启导入时自动 AI 分析" : "已关闭导入时自动 AI 分析")
                        }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "仅上传轻量化预览图",
                    subtitle: "大幅节省网络流量，避免发送原始高清大图"
                ) {
                    Toggle("", isOn: $draftAIConfig.sendThumbnailsToCloud)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: draftAIConfig.sendThumbnailsToCloud) { _, newVal in
                            persistAIConfigIfReady(message: newVal ? "已开启仅上传轻量化预览图" : "已切换为允许上传原图分析")
                        }
                }
            }
        }
    }

    // MARK: - Visual Enhancement Section (Human-Labeled TypeSafe)

    private var visualEnhancementSection: some View {
        let enabledCapabilitiesCount = [
            draftTypeSafeConfig.enableMoodboardFocusCrop,
            draftTypeSafeConfig.enableAutoCleanCrop,
            draftTypeSafeConfig.enableSubjectPalette,
            draftTypeSafeConfig.enableSemanticSearch,
            draftTypeSafeConfig.enableInboxSmartTriage,
            draftTypeSafeConfig.enableCuratorVisualRerank
        ].filter { $0 }.count

        return SettingsSection("进阶视觉定位（实验性）") {
            SettingsRow(
                title: "精准画面定位与智能分拣",
                subtitle: "开启后支持情绪板语义局部裁切、截图自动去噪、主体色板提取与收件箱智能归类；未开启时由本机 Apple Vision 兜底"
            ) {
                Toggle("", isOn: $draftTypeSafeConfig.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: draftTypeSafeConfig.enabled) { _, newVal in
                        persistTypeSafeConfigIfReady(message: newVal ? "已启用进阶视觉定位（TypeSafe）" : "已关闭进阶视觉定位（TypeSafe）")
                    }
            }

            if draftTypeSafeConfig.enabled {
                SettingsCardDivider()

                SettingsRow(
                    title: "TypeSafe 视觉定位引擎",
                    subtitle: syncAndAI.hasStoredTypeSafeKey
                        ? "已配置密钥 · 模型 \(draftTypeSafeConfig.model) · 已开启 \(enabledCapabilitiesCount)/6 项增强场景"
                        : "尚未填写 TypeSafe API 密钥，填写后即可启用精准定位与看图精排",
                    subtitleColor: syncAndAI.hasStoredTypeSafeKey
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : SettingsPalette.warningInk(for: colorScheme)
                ) {
                    HStack(spacing: 8) {
                        if syncAndAI.hasStoredTypeSafeKey {
                            Button {
                                let cfg = draftTypeSafeConfig
                                Task { _ = await syncAndAI.testTypeSafeConnection(config: cfg, apiKey: nil) }
                            } label: {
                                HStack(spacing: 5) {
                                    if syncAndAI.isTestingTypeSafe { ProgressView().controlSize(.mini) }
                                    Text(syncAndAI.isTestingTypeSafe ? "测试中…" : "测试连接")
                                }
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                            .disabled(syncAndAI.isTestingTypeSafe)
                        }

                        Button("密钥与功能开关…") {
                            typeSafeKeyInput = ""
                            showTypeSafeSheet = true
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }
            }

            InlineGuideDisclosure("这是什么？和上方云端 AI 有什么区别？") {
                SettingsGuideStep(
                    "1",
                    title: "与生成式大模型互补：专注「指哪打哪」的坐标定位与视觉评分",
                    detail: "普通大模型擅长描述画面和起标签；视觉定位引擎专门用来在图里精准圈出主体坐标、裁掉截图外壳，或给候选素材打分。"
                )
                SettingsGuideStep(
                    "2",
                    title: "完全可选，不开也不影响核心体验",
                    detail: "未开启时，主体聚焦与视觉相似自动回退至 macOS 原生 Apple Vision，零额外费用。"
                )
            }
        }
    }

    // MARK: - Usage Summary Section

    private var usageSummarySection: some View {
        let usage = syncAndAI.aiUsage
        let todayTotal = usage.standard.todayRequests + usage.jev.todayRequests
        let allTotalTokens = usage.standard.totalTokens + usage.jev.totalTokens

        return SettingsSection("用量统计") {
            SettingsRow(
                title: usage.totalRequests > 0
                    ? "今日 \(todayTotal) 次 · 累计 \(usage.totalRequests) 次（\(CloudAIUsageSummary.formatTokenCount(allTotalTokens)) tokens）"
                    : "暂无云端调用记录",
                subtitle: "分别统计普通云端模型与视觉定位引擎在本机的调用次数与 Token 消耗"
            ) {
                Button("查看明细…") {
                    syncAndAI.refreshAIUsage()
                    showUsageSheet = true
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .fixedSize()
            }
        }
    }

    // MARK: - Sheet 1: Cloud AI Provider Configuration

    private var cloudAIConfigSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("配置云端 AI 服务")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("所有 API 密钥与登录令牌均加密保存于本机 macOS 钥匙串。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            SettingsSheetFeedbackBanner(syncAndAI: syncAndAI)

            Picker("服务商", selection: $draftAIConfig.provider) {
                Text("关闭（仅本机）").tag(CloudAIProviderKind.disabled)
                Text("ChatGPT 订阅账号").tag(CloudAIProviderKind.chatGPTSubscription)
                Text("Google Gemini").tag(CloudAIProviderKind.gemini)
                Text("自定义兼容 API").tag(CloudAIProviderKind.openAICompatible)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: draftAIConfig.provider) { _, newProvider in
                applySmartAIDefaults(for: newProvider, format: draftAIConfig.customEndpointFormat)
                Task {
                    await syncAndAI.refreshAIKeyPresence(for: newProvider)
                }
            }

            switch draftAIConfig.provider {
            case .disabled:
                Text("关闭云端 AI 后，Charkle 仍会使用本机 Apple Vision 完成配色提取、OCR 文字识别、相似推荐与拼音搜索。")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        SettingsPalette.subtleFill(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                    )

            case .chatGPTSubscription:
                chatGPTConfigContent

            case .gemini:
                geminiConfigContent

            case .openAICompatible:
                customAPIConfigContent
            }

            HStack {
                Button("关闭") {
                    draftAIConfig = syncAndAI.aiConfig
                    apiKeyInput = ""
                    showCloudConfigSheet = false
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                if draftAIConfig.provider != .disabled {
                    Button {
                        let cfg = draftAIConfig
                        let keyDraft = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            _ = await syncAndAI.testAIConnection(
                                config: cfg,
                                apiKey: keyDraft.isEmpty ? nil : keyDraft
                            )
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if syncAndAI.isTestingAI { ProgressView().controlSize(.mini) }
                            Text(syncAndAI.isTestingAI ? "测试中…" : "测试连接")
                        }
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .disabled(syncAndAI.isTestingAI)
                }

                Button("保存配置") {
                    let cfg = draftAIConfig
                    let keyToSave = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await syncAndAI.saveAIConfig(cfg, apiKey: keyToSave.isEmpty ? nil : keyToSave)
                        apiKeyInput = ""
                        showCloudConfigSheet = false
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    @ViewBuilder
    private var chatGPTConfigContent: some View {
        let session = syncAndAI.chatGPTSession
        VStack(alignment: .leading, spacing: 12) {
            if session.status == .connected {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(SettingsPalette.subtleFill(for: colorScheme))
                            .frame(width: 36, height: 36)
                        SettingsHelpers.chatGPTBrandMark(size: 18, color: .primary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.displayName)
                                .font(CharkleTheme.text(.body, weight: .semibold))
                            SettingsStatusBadge(
                                session.sharingEnabled ? "已授权" : "需授权共享",
                                tint: session.sharingEnabled
                                    ? SettingsPalette.positiveInk(for: colorScheme)
                                    : SettingsPalette.warningInk(for: colorScheme)
                            )
                        }
                        if let email = session.email {
                            Text(email)
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                    if !session.sharingEnabled {
                        Button("授权额度共享") {
                            Task {
                                if await syncAndAI.signInWithChatGPT(reconsent: true, switchAccount: false) {
                                    draftAIConfig = syncAndAI.aiConfig
                                }
                            }
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .disabled(syncAndAI.isSigningInChatGPT)
                    } else {
                        Button("管理用量") {
                            NSWorkspace.shared.open(ChatGPTSignInClient.usageSettingsURL)
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    }

                    Button("退出") {
                        Task { await syncAndAI.disconnectChatGPT(resetRegistration: false) }
                    }
                    .buttonStyle(SettingsDestructiveButtonStyle())
                }
                .padding(12)
                .background(SettingsPalette.subtleFill(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))

                if session.sharingEnabled {
                    HStack(spacing: 8) {
                        Text("理解模型")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                        Spacer()
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
                            .frame(width: 220)
                        } else {
                            TextField("gpt-5.4-mini", text: $draftAIConfig.chatModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
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
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(syncAndAI.isLoadingChatGPTModels)
                    }

                    HStack {
                        Spacer()
                        Button("切换其他 ChatGPT 账号…") {
                            Task {
                                if await syncAndAI.signInWithChatGPT(reconsent: false, switchAccount: true) {
                                    draftAIConfig = syncAndAI.aiConfig
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    SettingsHelpers.chatGPTBrandMark(size: 20, color: .primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.status == .reauthRequired ? "ChatGPT 登录已过期" : "直接登录你的 ChatGPT 账号")
                            .font(CharkleTheme.text(.body, weight: .semibold))
                        Text("无需申请 API 密钥，支持 Plus / Pro 等订阅额度，凭证仅保存在本机钥匙串。")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(syncAndAI.isSigningInChatGPT ? "等待授权…" : "前往登录") {
                        Task {
                            if await syncAndAI.signInWithChatGPT(reconsent: false, switchAccount: false) {
                                draftAIConfig = syncAndAI.aiConfig
                            }
                        }
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .disabled(syncAndAI.isSigningInChatGPT)
                }
                .padding(12)
                .background(SettingsPalette.subtleFill(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
            }
        }
    }

    private var geminiConfigContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Gemini API 密钥")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(destination: SettingsHelpers.geminiKeyURL) {
                        HStack(spacing: 3) {
                            Text("前往 Google AI Studio 获取")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .font(CharkleTheme.text(.caption, weight: .medium))
                    }
                }
                SecureField(
                    syncAndAI.hasStoredAIKey ? "••••••••（已存钥匙串，留空不变）" : "粘贴 AIza… 密钥",
                    text: $apiKeyInput
                )
                .textFieldStyle(.roundedBorder)
            }

            CharkleDisclosureGroup(isExpanded: $showGeminiAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    sheetField("服务地址") {
                        TextField("https://generativelanguage.googleapis.com", text: $draftAIConfig.baseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    sheetField("理解模型") {
                        TextField("gemini-2.5-flash", text: $draftAIConfig.chatModel)
                            .textFieldStyle(.roundedBorder)
                    }
                    sheetField("搜索向量模型") {
                        TextField("gemini-embedding-001", text: $draftAIConfig.embeddingModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("高级模型与地址参数（可选）")
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customAPIConfigContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("一键填充常见服务商预设")
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Self.customPresets) { preset in
                        Button(preset.label) {
                            draftAIConfig.customEndpointFormat = preset.format
                            draftAIConfig.baseURL = preset.baseURL
                            draftAIConfig.chatModel = preset.chatModel
                            draftAIConfig.embeddingModel = preset.embeddingModel
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                    }
                }
            }

            sheetField("端点格式") {
                Picker("", selection: $draftAIConfig.customEndpointFormat) {
                    ForEach(CustomAIEndpointFormat.allCases, id: \.self) { fmt in
                        Text(fmt.localizedLabel).tag(fmt)
                    }
                }
                .labelsHidden()
                .onChange(of: draftAIConfig.customEndpointFormat) { _, newFmt in
                    applySmartAIDefaults(for: .openAICompatible, format: newFmt)
                }
            }

            sheetField("服务地址（自动补全 /v1）") {
                TextField(draftAIConfig.customEndpointFormat.defaultBaseURL, text: $draftAIConfig.baseURL)
                    .textFieldStyle(.roundedBorder)
            }

            sheetField("API 密钥（Ollama 本地可留空）") {
                SecureField(
                    syncAndAI.hasStoredAIKey ? "••••••••（已存钥匙串，留空不变）" : "粘贴 API 密钥…",
                    text: $apiKeyInput
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 10) {
                sheetField("理解模型") {
                    TextField(draftAIConfig.customEndpointFormat.defaultChatModel, text: $draftAIConfig.chatModel)
                        .textFieldStyle(.roundedBorder)
                }
                if draftAIConfig.customEndpointFormat.supportsEmbeddings {
                    sheetField("向量模型（可选）") {
                        TextField("text-embedding-3-small", text: $draftAIConfig.embeddingModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    // MARK: - Sheet 2: TypeSafe Visual Enhancement Configuration

    private var typeSafeConfigSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("进阶视觉定位引擎配置")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("配置 TypeSafe 密钥并按需勾选视觉定位场景，密钥安全保存于 macOS 钥匙串。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: SettingsHelpers.typeSafeHomeURL) {
                    HStack(spacing: 3) {
                        Text("获取密钥")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(CharkleTheme.text(.caption, weight: .medium))
                }
            }

            SettingsSheetFeedbackBanner(syncAndAI: syncAndAI)

            sheetField("TypeSafe API 密钥") {
                SecureField(
                    syncAndAI.hasStoredTypeSafeKey ? "••••••••（已存钥匙串，留空不变）" : "粘贴 apikey_…",
                    text: $typeSafeKeyInput
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                sheetField("视觉定位模型") {
                    HStack(spacing: 6) {
                        TextField("jev-latest", text: $draftTypeSafeConfig.model)
                            .textFieldStyle(.roundedBorder)
                        if !syncAndAI.typeSafeModels.isEmpty {
                            Menu {
                                ForEach(syncAndAI.typeSafeModels) { item in
                                    Button(item.name) {
                                        draftTypeSafeConfig.model = item.name
                                    }
                                }
                            } label: {
                                CharkleDropdownChevron(size: 10)
                                    .frame(width: 24, height: 24)
                            }
                            .menuStyle(.button)
                            .buttonStyle(CharkleMenuTriggerButtonStyle())
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .frame(width: 24)
                        }
                    }
                }

                sheetField("低置信度防切边阈值（\(Int((draftTypeSafeConfig.minConfidence * 100).rounded()))%）") {
                    Slider(value: $draftTypeSafeConfig.minConfidence, in: 0.30...0.90, step: 0.05)
                }
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    scenarioToggle(
                        title: "情绪板语义局部裁切",
                        subtitle: "右键支持「聚焦主体」与「一句话语义裁切」，非破坏性保留原图",
                        isOn: $draftTypeSafeConfig.enableMoodboardFocusCrop
                    )
                    SettingsCardDivider()
                    scenarioToggle(
                        title: "截图与网页自动去噪裁净",
                        subtitle: "自动识别浏览器外壳、状态栏与白边并裁净核心作品",
                        isOn: $draftTypeSafeConfig.enableAutoCleanCrop
                    )
                    SettingsCardDivider()
                    scenarioToggle(
                        title: "主体色板提取与指物批注",
                        subtitle: "过滤背景干扰色提取主体色卡，批注箭头自动指向目标物体",
                        isOn: Binding(
                            get: { draftTypeSafeConfig.enableSubjectPalette },
                            set: { newVal in
                                draftTypeSafeConfig.enableSubjectPalette = newVal
                                draftTypeSafeConfig.enablePinpointAnnotations = newVal
                            }
                        )
                    )
                    SettingsCardDivider()
                    scenarioToggle(
                        title: "自然语言看图语义搜索",
                        subtitle: "在搜索栏输入描述时自动融合视觉语义精排，未打标素材也能直接命中",
                        isOn: $draftTypeSafeConfig.enableSemanticSearch
                    )
                    SettingsCardDivider()
                    scenarioToggle(
                        title: "收件箱智能归档分拣",
                        subtitle: "将待整理素材精准推荐到最匹配的已有文件夹",
                        isOn: $draftTypeSafeConfig.enableInboxSmartTriage
                    )
                    SettingsCardDivider()
                    scenarioToggle(
                        title: "情绪板策展视觉精排",
                        subtitle: "对候选池进行视觉相关度精排，并支持细节特写生板模式",
                        isOn: $draftTypeSafeConfig.enableCuratorVisualRerank
                    )
                }
                .background(
                    SettingsPalette.subtleFill(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
                .charkleCleanScrollbars(hidden: false)
            }
            .frame(maxHeight: 240)

            CharkleDisclosureGroup(isExpanded: $showTypeSafeEndpoint) {
                sheetField("自定义服务地址（默认 https://api.typesafe.ai）") {
                    TextField("https://api.typesafe.ai", text: $draftTypeSafeConfig.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 6)
            } label: {
                Text("自定义服务地址（可选）")
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("取消") {
                    draftTypeSafeConfig = syncAndAI.typeSafeConfig
                    typeSafeKeyInput = ""
                    showTypeSafeSheet = false
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    let keyDraft = typeSafeKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cfg = draftTypeSafeConfig
                    Task {
                        _ = await syncAndAI.testTypeSafeConnection(
                            config: cfg,
                            apiKey: keyDraft.isEmpty ? nil : keyDraft
                        )
                    }
                } label: {
                    HStack(spacing: 5) {
                        if syncAndAI.isTestingTypeSafe { ProgressView().controlSize(.mini) }
                        Text(syncAndAI.isTestingTypeSafe ? "测试中…" : "测试连接")
                    }
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(syncAndAI.isTestingTypeSafe)

                Button("保存配置") {
                    let keyDraft = typeSafeKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let cfg = draftTypeSafeConfig
                    Task {
                        await syncAndAI.saveTypeSafeConfig(cfg, apiKey: keyDraft.isEmpty ? nil : keyDraft)
                        typeSafeKeyInput = ""
                        showTypeSafeSheet = false
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func scenarioToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CharkleTheme.text(.body, weight: .medium))
                Text(subtitle)
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Sheet 3: Usage Detail Sheet

    private var usageDetailSheet: some View {
        let usage = syncAndAI.aiUsage
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("云端 AI 用量明细")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("记录保存于本机，分别统计普通云端模型与视觉定位引擎的调用消耗。")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if usage.totalRequests > 0 {
                    Button("全部清零") {
                        syncAndAI.resetAIUsage(category: nil)
                    }
                    .buttonStyle(SettingsDestructiveButtonStyle())
                }
            }

            usageBucketCard(
                title: "普通云端模型",
                subtitle: "画面理解、标签建议与情绪板策展",
                bucket: usage.standard,
                emptyHint: "调用 ChatGPT / Gemini / 自定义模型后将记录在此。",
                onReset: { syncAndAI.resetAIUsage(category: .standard) }
            )

            usageBucketCard(
                title: "视觉定位引擎（TypeSafe）",
                subtitle: "语义局部裁切、去噪、视觉评分与智能分拣",
                bucket: usage.jev,
                emptyHint: "开启并调用视觉定位引擎后将单独记录在此。",
                onReset: { syncAndAI.resetAIUsage(category: .jev) }
            )

            HStack {
                Spacer()
                Button("完成") {
                    showUsageSheet = false
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func usageBucketCard(
        title: String,
        subtitle: String,
        bucket: CloudAIUsageBucket,
        emptyHint: String,
        onReset: @escaping () -> Void
    ) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(title)
                            .font(CharkleTheme.text(.body, weight: .semibold))
                        Text(subtitle)
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if bucket.totalRequests > 0 {
                        Button("清零", action: onReset)
                            .buttonStyle(SettingsSecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                SettingsCardDivider()

                HStack(spacing: 0) {
                    metricCell("今日调用", value: "\(bucket.todayRequests) 次", detail: "Token \(CloudAIUsageSummary.formatTokenCount(bucket.todayTotalTokens))")
                    CharkleHairlineDivider(axis: .vertical)
                        .frame(height: 40)
                    metricCell("累计调用", value: "\(bucket.totalRequests) 次", detail: bucket.lastModel ?? "尚未调用")
                    CharkleHairlineDivider(axis: .vertical)
                        .frame(height: 40)
                    metricCell("累计 Token", value: CloudAIUsageSummary.formatTokenCount(bucket.totalTokens), detail: "入 \(CloudAIUsageSummary.formatTokenCount(bucket.totalInputTokens)) / 出 \(CloudAIUsageSummary.formatTokenCount(bucket.totalOutputTokens))")
                }
                .padding(.vertical, 10)

                SettingsCardDivider()

                Group {
                    if let usedAt = bucket.lastUsedAt {
                        let provider = bucket.lastProviderLabel ?? title
                        let modelPart = bucket.lastModel.map { " (\($0))" } ?? ""
                        Text("最近调用：\(provider)\(modelPart) · \(SettingsHelpers.relativeTimeText(usedAt))")
                    } else {
                        Text(emptyHint)
                    }
                }
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private func metricCell(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(CharkleTheme.text(.body, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    // MARK: - Helpers

    private var cloudDisconnectedTitle: String {
        switch draftAIConfig.provider {
        case .disabled: "尚未开启云端增强智能"
        case .chatGPTSubscription:
            syncAndAI.chatGPTSession.status == .reauthRequired ? "ChatGPT 登录已过期" : "ChatGPT 订阅尚未完成授权"
        case .gemini: "Google Gemini 尚未配置密钥"
        case .openAICompatible: "自定义 API 尚未配置完成"
        }
    }

    private var cloudDisconnectedSubtitle: String {
        switch draftAIConfig.provider {
        case .disabled:
            "连接后可自动生成画面描述、建议标签，并大幅提升灵感词生板准确度"
        case .chatGPTSubscription:
            "直接登录你的 ChatGPT Plus / Pro 账号即可使用，无需手动管理 API 密钥"
        case .gemini:
            "前往「Gemini / 自定义 API…」粘贴 Google AI Studio 密钥并测试连接"
        case .openAICompatible:
            "前往「Gemini / 自定义 API…」填写服务地址、模型与密钥"
        }
    }

    private var cloudConnectedTitle: String {
        switch draftAIConfig.provider {
        case .disabled: "已关闭"
        case .chatGPTSubscription: "ChatGPT 订阅账号"
        case .gemini: "Google Gemini"
        case .openAICompatible: draftAIConfig.customEndpointFormat.localizedLabel
        }
    }

    private var cloudConnectedSubtitle: String {
        let model = draftAIConfig.chatModel.isEmpty ? "默认模型" : draftAIConfig.chatModel
        switch draftAIConfig.provider {
        case .disabled:
            return "仅使用本机离线能力"
        case .chatGPTSubscription:
            let account = syncAndAI.chatGPTSession.email ?? syncAndAI.chatGPTSession.displayName
            return "已连接（\(account)）· 当前模型：\(model)"
        case .gemini:
            return "已连接 · 当前模型：\(model)"
        case .openAICompatible:
            let host = URL(string: draftAIConfig.baseURL)?.host() ?? draftAIConfig.baseURL
            return "已连接（\(host)）· 当前模型：\(model)"
        }
    }

    private func sheetField<F: View>(_ label: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            field()
        }
    }

    private func persistAIConfigIfReady(message: String? = nil) {
        guard didLoadDraft else { return }
        let snapshot = draftAIConfig
        guard snapshot != syncAndAI.aiConfig else { return }
        Task {
            await syncAndAI.saveAIConfig(
                snapshot,
                apiKey: nil,
                quiet: message == nil,
                successMessage: message
            )
        }
    }

    private func persistTypeSafeConfigIfReady(message: String? = nil) {
        guard didLoadDraft else { return }
        let snapshot = draftTypeSafeConfig
        guard snapshot != syncAndAI.typeSafeConfig else { return }
        Task {
            await syncAndAI.saveTypeSafeConfig(
                snapshot,
                apiKey: nil,
                quiet: message == nil,
                successMessage: message
            )
        }
    }

    private func applySmartAIDefaults(for provider: CloudAIProviderKind, format: CustomAIEndpointFormat) {
        let knownDefaultURLs: Set<String> = [
            "",
            ChatGPTSignInClient.resource,
            "https://generativelanguage.googleapis.com",
            "https://api.openai.com",
            "https://api.openai.com/v1",
            "https://api.anthropic.com",
            "https://openrouter.ai/api/v1",
            "https://api.deepseek.com/v1",
            "http://localhost:11434/v1"
        ]
        let knownDefaultChats: Set<String> = [
            "",
            "gemini-2.5-flash",
            "gpt-4.1-mini",
            "gpt-5.4-mini",
            "claude-sonnet-4-5",
            "google/gemini-2.5-flash",
            "deepseek-chat",
            "qwen2.5vl:7b"
        ]
        let knownDefaultEmbeddings: Set<String> = [
            "",
            "gemini-embedding-001",
            "text-embedding-3-small",
            "nomic-embed-text"
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
}

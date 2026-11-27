import CharkleCore
import SwiftUI

/// Tab 7: 外部 Agent (Pure MCP v2) — Dual-transport MCP setup:
/// 1. Local headless `stdio` MCP (`charkle mcp`, works even when `Charkle.app` is closed)
/// 2. Streamable HTTP MCP (`/api/v1/mcp` + Scoped Bearer Tokens) for remote / cross-machine Agents
public struct ExternalAgentsSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let syncAndAI: SyncAndAIStore

    @State private var draftConfig: ExternalAgentConfig = ExternalAgentConfig()
    @State private var newTokenName: String = ""
    @State private var newTokenScope: ExternalAgentAccessLevel = .inboxAndEnrich

    private static let samplePrompts: [(title: String, prompt: String)] = [
        ("找参考图并建情绪板", "帮我用 Charkle MCP 挑 10 张温暖胶片质感、偏奶油色调的咖啡馆参考图，先看联系表去重，再生成一块名为「早秋咖啡馆视觉」的情绪板。"),
        ("批量智能整理收件箱", "帮我查看 Charkle 收件箱里未整理的素材并附上文件夹建议，先用 dry_run 给我看变更摘要，确认后再一次批量归档到现有文件夹。"),
        ("视觉去重清理", "扫描 Charkle 素材库中的重复图片并拼出对比联系表，帮我挑出画质最干净的无水印版本，确认后合并标签并把副本移入废纸篓。"),
        ("撤回上一次 AI 整理", "查看 Charkle 最近一次外部 Agent 整理记录（run_id），并帮我一键回滚。")
    ]

    public init(syncAndAI: SyncAndAIStore) {
        self.syncAndAI = syncAndAI
    }

    private var bridge: ExtensionBridgeController {
        CharkleRuntime.shared.extensionBridge
    }

    public var body: some View {
        let helperPath = syncAndAI.resolvedHelperMCPPath()
        let helperReady = syncAndAI.isBundledHelperAvailable
        let claudeCodeCmd = "claude mcp add charkle -- \"\(helperPath)\" mcp"
        let codexCmd = "codex mcp add charkle -- \"\(helperPath)\" mcp"
        let stdioJSON = """
        {
          "mcpServers": {
            "charkle": {
              "command": "\(helperPath)",
              "args": ["mcp"]
            }
          }
        }
        """

        let activeEndpoint = (draftConfig.allowRemoteHTTPMCP ? bridge.mcpRemoteEndpointURL : nil) ?? bridge.mcpLocalEndpointURL
        let previewToken = syncAndAI.lastCreatedAgentTokenPlaintext ?? "<你的_CHARKLE_MCP_TOKEN>"
        let httpJSON = """
        {
          "mcpServers": {
            "charkle-remote": {
              "type": "http",
              "url": "\(activeEndpoint)",
              "headers": {
                "Authorization": "Bearer \(previewToken)"
              }
            }
          }
        }
        """

        let stdioEnabledBinding = Binding<Bool>(
            get: { draftConfig.mcpEnabled },
            set: { newValue in
                draftConfig.mcpEnabled = newValue
                syncAndAI.saveExternalAgentConfig(draftConfig)
            }
        )
        let httpEnabledBinding = Binding<Bool>(
            get: { draftConfig.httpMCPEnabled },
            set: { newValue in
                draftConfig.httpMCPEnabled = newValue
                syncAndAI.saveExternalAgentConfig(draftConfig)
            }
        )
        let remoteBindBinding = Binding<Bool>(
            get: { draftConfig.allowRemoteHTTPMCP },
            set: { newValue in
                draftConfig.allowRemoteHTTPMCP = newValue
                syncAndAI.saveExternalAgentConfig(draftConfig)
            }
        )
        let accessBinding = Binding<ExternalAgentAccessLevel>(
            get: { draftConfig.accessLevel },
            set: { newLevel in
                draftConfig.accessLevel = newLevel
                syncAndAI.saveExternalAgentConfig(draftConfig)
            }
        )

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("MCP 双通道开关与安全边界") {
                SettingsRow(
                    title: "本机 MCP 服务（stdio）",
                    subtitle: stdioStatusSubtitle(enabled: draftConfig.mcpEnabled, helperReady: helperReady),
                    subtitleColor: !draftConfig.mcpEnabled
                        ? .secondary
                        : (helperReady
                            ? SettingsPalette.positiveInk(for: colorScheme)
                            : SettingsPalette.warningInk(for: colorScheme))
                ) {
                    HStack(spacing: 10) {
                        SettingsStatusBadge(
                            draftConfig.mcpEnabled ? "已开启" : "已关闭",
                            tint: draftConfig.mcpEnabled
                                ? SettingsPalette.positiveInk(for: colorScheme)
                                : SettingsPalette.sectionLabel(for: colorScheme)
                        )
                        Toggle("", isOn: stdioEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                if draftConfig.mcpEnabled {
                    SettingsCardDivider()

                    SettingsRow(
                        title: "本机 stdio 访问权限",
                        subtitle: draftConfig.accessLevel.summary
                    ) {
                        Picker("", selection: accessBinding) {
                            ForEach(ExternalAgentAccessLevel.allCases, id: \.self) { level in
                                Text(level.displayTitle).tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 286)
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "HTTP MCP 服务（跨机器 / 远程接入）",
                    subtitle: httpStatusSubtitle(enabled: draftConfig.httpMCPEnabled, isRunning: bridge.isRunning, endpoint: activeEndpoint),
                    subtitleColor: draftConfig.httpMCPEnabled && bridge.isRunning
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : .secondary
                ) {
                    HStack(spacing: 10) {
                        SettingsStatusBadge(
                            draftConfig.httpMCPEnabled ? (bridge.isRunning ? "监听中" : "已开启") : "已关闭",
                            tint: draftConfig.httpMCPEnabled && bridge.isRunning
                                ? SettingsPalette.positiveInk(for: colorScheme)
                                : SettingsPalette.sectionLabel(for: colorScheme)
                        )
                        Toggle("", isOn: httpEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                if draftConfig.httpMCPEnabled {
                    SettingsCardDivider()

                    SettingsRow(
                        title: "允许跨机器远程接入（局域网 / Tailscale）",
                        subtitle: draftConfig.allowRemoteHTTPMCP
                            ? "HTTP MCP 已监听所有网卡（必须携带独立作用域密钥）；浏览器扩展接口仍严格限制本机 127.0.0.1"
                            : "默认仅限本机 127.0.0.1 访问；开启后可让其他电脑、容器或云端沙箱通过局域网 / Tailscale 远程接入"
                    ) {
                        Toggle("", isOn: remoteBindBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                if draftConfig.mcpEnabled || draftConfig.httpMCPEnabled {
                    SettingsCardDivider()

                    SettingsRow(
                        title: "MCP v2 内核与数据库自检",
                        subtitle: syncAndAI.externalAgentSelfCheckSummary
                            ?? "验证 10 项纯 MCP 安全工具、5 项动态资源、5 套工作流与 SQLite WAL 数据库连通性",
                        subtitleColor: selfCheckSubtitleColor()
                    ) {
                        Button(syncAndAI.isRunningExternalAgentSelfCheck ? "自检中…" : "运行自检") {
                            Task { await syncAndAI.runExternalAgentSelfCheck() }
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(syncAndAI.isRunningExternalAgentSelfCheck)
                        .fixedSize()
                    }

                    InlineGuideDisclosure("安全边界与撤销保障") {
                        SettingsGuideStep(
                            "1",
                            title: "永不允许彻底删除素材或删文件夹",
                            detail: "即使开启最高权限，所有移除与去重合并均只能移入可恢复废纸篓。"
                        )
                        SettingsGuideStep(
                            "2",
                            title: "每次写操作自动签发 run_id，支持一键跨端回滚",
                            detail: "批量整理、改目录、修补情绪板与去重合并均可随时调用 rollback_run 无损撤销并同步五端。"
                        )
                        SettingsGuideStep(
                            "3",
                            title: "远程 HTTP MCP 严格隔离本机硬盘路径与扩展配对",
                            detail: "远程密钥以 SHA-256 哈希存储，禁用服务端 file_path 探测；浏览器扩展自动配对永久锁定 127.0.0.1。"
                        )
                    }
                }
            }

            if draftConfig.httpMCPEnabled {
                SettingsSection("远程 HTTP MCP 地址与作用域密钥（Scoped Tokens）") {
                    SettingsRow(
                        title: "HTTP MCP 接口地址",
                        subtitle: activeEndpoint
                    ) {
                        HStack(spacing: 8) {
                            Button("复制地址") {
                                SettingsHelpers.copyToClipboard(
                                    activeEndpoint,
                                    toast: "已复制 HTTP MCP 地址",
                                    syncAndAI: syncAndAI
                                )
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()

                            Button("复制 JSON 配置") {
                                SettingsHelpers.copyToClipboard(
                                    httpJSON,
                                    toast: "已复制 HTTP MCP JSON 配置",
                                    syncAndAI: syncAndAI
                                )
                            }
                            .buttonStyle(SettingsPrimaryButtonStyle())
                            .fixedSize()
                        }
                    }

                    SettingsCardDivider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("创建新的作用域密钥（每把钥匙独立绑定权限，互不干扰）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("例如：云端开发机 / 收件箱自动分拣", text: $newTokenName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))

                            Picker("", selection: $newTokenScope) {
                                ForEach(ExternalAgentAccessLevel.allCases, id: \.self) { level in
                                    Text(level.displayTitle).tag(level)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 136)

                            Button("新建密钥") {
                                syncAndAI.createExternalAgentToken(name: newTokenName, accessLevel: newTokenScope)
                                newTokenName = ""
                                draftConfig = syncAndAI.externalAgentConfig
                            }
                            .buttonStyle(SettingsPrimaryButtonStyle())
                            .fixedSize()
                        }

                        if let freshToken = syncAndAI.lastCreatedAgentTokenPlaintext {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("新密钥「\(syncAndAI.lastCreatedAgentTokenName ?? "")」明文仅显示一次，请妥善复制：")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(SettingsPalette.positiveInk(for: colorScheme))
                                    Spacer()
                                    Button("复制密钥") {
                                        SettingsHelpers.copyToClipboard(
                                            freshToken,
                                            toast: "已复制远程 MCP 密钥",
                                            syncAndAI: syncAndAI
                                        )
                                    }
                                    .buttonStyle(SettingsSecondaryButtonStyle())
                                    .fixedSize()
                                    Button("隐藏") {
                                        syncAndAI.clearCreatedAgentTokenBanner()
                                    }
                                    .buttonStyle(SettingsSecondaryButtonStyle())
                                    .fixedSize()
                                }
                                SettingsCodeSnippet(freshToken)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(SettingsPalette.positiveInk(for: colorScheme).opacity(0.08))
                            )
                        }
                    }
                    .padding(.vertical, 4)

                    if !draftConfig.tokens.isEmpty {
                        SettingsCardDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(draftConfig.tokens.enumerated()), id: \.element.id) { index, token in
                                if index > 0 {
                                    CharkleHairlineDivider()
                                }
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(token.name)
                                                .font(.system(size: 12, weight: .semibold))
                                            SettingsStatusBadge(
                                                token.accessLevel.displayTitle,
                                                tint: token.isEnabled
                                                    ? SettingsPalette.positiveInk(for: colorScheme)
                                                    : SettingsPalette.sectionLabel(for: colorScheme)
                                            )
                                        }
                                        Text("\(token.tokenPrefix)…")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 8)

                                    Toggle("", isOn: Binding(
                                        get: { token.isEnabled },
                                        set: { enabled in
                                            syncAndAI.setExternalAgentTokenEnabled(id: token.id, enabled: enabled)
                                            draftConfig = syncAndAI.externalAgentConfig
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)

                                    Button("吊销") {
                                        syncAndAI.revokeExternalAgentToken(id: token.id)
                                        draftConfig = syncAndAI.externalAgentConfig
                                    }
                                    .buttonStyle(SettingsSecondaryButtonStyle())
                                    .fixedSize()
                                }
                            }
                        }
                    }

                    InlineGuideDisclosure("查看远程 HTTP MCP JSON 配置片段") {
                        SettingsCodeSnippet(httpJSON)
                    }
                }
            }

            SettingsSection(
                "接入本机 AI 客户端（stdio MCP · 关软件也能用）",
                caption: draftConfig.mcpEnabled ? nil : "本机 stdio MCP 已关闭 · 开启上方开关后生效"
            ) {
                SettingsRow(
                    title: "Claude Code / Codex",
                    subtitle: "一行命令即可将 Charkle 注册为本机零依赖原生 MCP 服务"
                ) {
                    Button("复制 Claude Code 命令") {
                        SettingsHelpers.copyToClipboard(
                            claudeCodeCmd,
                            toast: "已复制 Claude Code 接入命令",
                            syncAndAI: syncAndAI
                        )
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }

                InlineGuideDisclosure("查看 Claude Code / Codex 接入命令") {
                    SettingsCodeSnippet(claudeCodeCmd + "\n" + codexCmd)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "Antigravity / Cursor / Claude Desktop",
                    subtitle: "复制标准 stdio MCP JSON 粘贴至客户端配置即可"
                ) {
                    Button("复制 JSON 配置") {
                        SettingsHelpers.copyToClipboard(
                            stdioJSON,
                            toast: "已复制本机 stdio MCP JSON 配置",
                            syncAndAI: syncAndAI
                        )
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }

                InlineGuideDisclosure("查看本机 stdio MCP JSON 配置片段") {
                    SettingsCodeSnippet(stdioJSON)
                }
            }
            .opacity(draftConfig.mcpEnabled ? 1.0 : 0.72)

            SettingsSection("MCP v2 能力清单与推荐对话") {
                SettingsRow(
                    title: "10 项正交安全工具 · 5 项动态资源 · 5 套内置工作流",
                    subtitle: "library_overview / query_assets（一跳联系表 + 会话去重）/ inspect_assets（局部放大 + 跨机下载）/ get_board / ingest_assets（跨机上传）/ organize_assets（异构批量 + dry_run）/ manage_folder / save_moodboard / deduplicate_assets / rollback_run"
                ) {
                    EmptyView()
                }

                InlineGuideDisclosure("不知道怎么跟 AI 开口？查看 4 条推荐对话示例") {
                    ForEach(Array(Self.samplePrompts.enumerated()), id: \.element.title) { index, item in
                        if index > 0 {
                            CharkleHairlineDivider()
                        }
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                Text("“\(item.prompt)”")
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button("复制") {
                                SettingsHelpers.copyToClipboard(
                                    item.prompt,
                                    toast: "已复制示例提示词",
                                    syncAndAI: syncAndAI
                                )
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .onAppear {
            draftConfig = syncAndAI.externalAgentConfig
        }
        .onChange(of: syncAndAI.externalAgentConfig) { _, latest in
            draftConfig = latest
        }
    }

    private func stdioStatusSubtitle(enabled: Bool, helperReady: Bool) -> String {
        guard enabled else {
            return "已关闭 · 本机 stdio MCP 客户端请求将被即时拦截"
        }
        return helperReady
            ? "原生 Swift stdio MCP 助手已就绪 · 10 项精简安全工具，App 退出亦可静默查库"
            : "当前运行在开发态，正式打包为 Charkle.app 后将自动内置原生 stdio MCP 助手"
    }

    private func httpStatusSubtitle(enabled: Bool, isRunning: Bool, endpoint: String) -> String {
        guard enabled else {
            return "已关闭 · 远程与本地 HTTP MCP 请求均被拦截"
        }
        return isRunning
            ? "已就绪 · 监听 \(endpoint)（需携带作用域密钥）"
            : "已开启 · 等待内置 HTTP 服务启动"
    }

    private func selfCheckSubtitleColor() -> Color {
        guard let passed = syncAndAI.externalAgentSelfCheckPassed else { return .secondary }
        return passed
            ? SettingsPalette.positiveInk(for: colorScheme)
            : SettingsPalette.warningInk(for: colorScheme)
    }
}

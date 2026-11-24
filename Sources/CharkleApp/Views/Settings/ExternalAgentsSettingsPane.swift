import CharkleCore
import SwiftUI

/// Tab 7: 外部 Agent (Agents) — Native stdio MCP server & CLI setup with live readiness detection,
/// stale-symlink diagnostics, one-click self-check, folded client snippets, and copyable prompts.
public struct ExternalAgentsSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let syncAndAI: SyncAndAIStore

    @State private var draftConfig: ExternalAgentConfig = ExternalAgentConfig()

    private static let samplePrompts: [(title: String, prompt: String)] = [
        ("找参考图并建情绪板", "帮我从 Charkle 素材库里挑 10 张温暖胶片质感、偏奶油色调的咖啡馆参考图，先用联系表看图确认无重复，再生成一块名为「早秋咖啡馆视觉」的情绪板。"),
        ("智能整理收件箱", "帮我用联系表和文件夹推荐看看 Charkle 收件箱里未整理的素材，按画面风格建议归档到现有文件夹，并补齐统一标签。"),
        ("提取情绪板色板与 AI 配方", "读取我在 Charkle 里名为「品牌改版」的情绪板，导出主色板 HEX、分区批注与其中 AI 参考图的生成 Prompt，帮我整理成设计规范。")
    ]

    public init(syncAndAI: SyncAndAIStore) {
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        let helperPath = syncAndAI.resolvedHelperCLIPath()
        let helperReady = syncAndAI.isBundledHelperAvailable
        let linkStatus = syncAndAI.cliLinkStatus
        let claudeCodeCmd = "claude mcp add charkle -- \"\(helperPath)\" mcp"
        let codexCmd = "codex mcp add charkle -- \"\(helperPath)\" mcp"
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

        let mcpEnabledBinding = Binding<Bool>(
            get: { draftConfig.mcpEnabled },
            set: { newValue in
                draftConfig.mcpEnabled = newValue
                syncAndAI.saveExternalAgentConfig(draftConfig)
            }
        )
        let cliEnabledBinding = Binding<Bool>(
            get: { draftConfig.cliEnabled },
            set: { newValue in
                draftConfig.cliEnabled = newValue
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
            SettingsSection("服务开关与安全边界") {
                SettingsRow(
                    title: "启用 MCP 服务",
                    subtitle: mcpStatusSubtitle(enabled: draftConfig.mcpEnabled, helperReady: helperReady),
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
                        Toggle("", isOn: mcpEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "启用 CLI 命令行服务",
                    subtitle: cliStatusSubtitle(enabled: draftConfig.cliEnabled, linkStatus: linkStatus),
                    subtitleColor: cliStatusColor(enabled: draftConfig.cliEnabled, linkStatus: linkStatus)
                ) {
                    HStack(spacing: 10) {
                        SettingsStatusBadge(
                            draftConfig.cliEnabled ? "已开启" : "已关闭",
                            tint: draftConfig.cliEnabled
                                ? SettingsPalette.positiveInk(for: colorScheme)
                                : SettingsPalette.sectionLabel(for: colorScheme)
                        )
                        Toggle("", isOn: cliEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                if draftConfig.mcpEnabled || draftConfig.cliEnabled {
                    SettingsCardDivider()

                    SettingsRow(
                        title: "外部访问权限级别",
                        subtitle: draftConfig.accessLevel.summary
                    ) {
                        Picker("", selection: accessBinding) {
                            Text("仅只读").tag(ExternalAgentAccessLevel.readOnly)
                            Text("允许整理与生板").tag(ExternalAgentAccessLevel.readWriteOrganize)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 224)
                    }

                    SettingsCardDivider()

                    SettingsRow(
                        title: "原生助手与数据库连通自检",
                        subtitle: syncAndAI.externalAgentSelfCheckSummary
                            ?? "验证内置 charkle 原生二进制、SQLite WAL 数据库、20 项安全工具与 4 套工作流 Prompts",
                        subtitleColor: selfCheckSubtitleColor()
                    ) {
                        Button(syncAndAI.isRunningExternalAgentSelfCheck ? "自检中…" : "运行自检") {
                            Task { await syncAndAI.runExternalAgentSelfCheck() }
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .disabled(syncAndAI.isRunningExternalAgentSelfCheck)
                        .fixedSize()
                    }

                    InlineGuideDisclosure("数据安全如何保障？") {
                        SettingsGuideStep(
                            "1",
                            title: "MCP 与 CLI 独立管控，关闭即刻生效",
                            detail: "可按需只保留其中一项服务；关闭任意开关后，对应通道的新请求会立即被拦截。"
                        )
                        SettingsGuideStep(
                            "2",
                            title: "永不开放公网或局域网端口",
                            detail: "所有调用均通过本机标准输入输出（stdio）或本地 CLI 与 WAL 数据库通信，外部网络无法访问。"
                        )
                        SettingsGuideStep(
                            "3",
                            title: "永不允许彻底删除素材或文件夹",
                            detail: "即使开启「允许整理与生板」，外部 Agent 也只能将素材移入废纸篓，随时可恢复。"
                        )
                    }
                }
            }

            SettingsSection(
                "接入常用 AI 客户端（MCP）",
                caption: draftConfig.mcpEnabled ? nil : "MCP 服务已关闭 · 开启上方开关后生效"
            ) {
                SettingsRow(
                    title: "Claude Code",
                    subtitle: "在终端执行一行命令即可将 Charkle 注册为原生 MCP 工具与 Prompts"
                ) {
                    Button("一键复制命令") {
                        SettingsHelpers.copyToClipboard(
                            claudeCodeCmd,
                            toast: "已复制 Claude Code 接入命令",
                            syncAndAI: syncAndAI
                        )
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }

                InlineGuideDisclosure("查看 Claude Code / Codex CLI 接入命令") {
                    SettingsCodeSnippet(claudeCodeCmd + "\n" + codexCmd)
                    SettingsGuideStep(
                        "1",
                        title: "在终端粘贴运行对应命令，完成后重启对话",
                        detail: "输入「看看我的 Charkle 素材库概览」或触发内置 `triage_inbox` / `curate_moodboard` 工作流即可验证连通。"
                    )
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "Cursor / Antigravity / 其他 MCP 客户端",
                    subtitle: "复制标准 MCP JSON 配置粘贴至对应客户端的配置文件"
                ) {
                    Button("复制 JSON 配置") {
                        SettingsHelpers.copyToClipboard(
                            jsonConfig,
                            toast: "已复制 MCP JSON 配置",
                            syncAndAI: syncAndAI
                        )
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }

                InlineGuideDisclosure("查看 MCP JSON 配置片段") {
                    SettingsCodeSnippet(jsonConfig)
                }
            }
            .opacity(draftConfig.mcpEnabled ? 1.0 : 0.72)

            SettingsSection(
                "终端命令行（charkle CLI）",
                caption: draftConfig.cliEnabled ? nil : "CLI 服务已关闭 · 开启上方开关后生效"
            ) {
                SettingsRow(
                    title: "本机命令链接",
                    subtitle: cliLinkRowSubtitle(linkStatus),
                    subtitleColor: cliLinkRowColor(linkStatus)
                ) {
                    HStack(spacing: 8) {
                        Button("复制路径") {
                            SettingsHelpers.copyToClipboard(
                                helperPath,
                                toast: "已复制 charkle 可执行文件路径",
                                syncAndAI: syncAndAI
                            )
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()

                        Button(cliLinkButtonTitle(linkStatus)) {
                            syncAndAI.installCLIInLocalBin()
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }

                InlineGuideDisclosure("常用命令行示例（交互终端自动排版，管道自动输出 JSON）") {
                    SettingsCodeSnippet(
                        """
                        charkle doctor
                        charkle overview
                        charkle search "暖调陶艺" --subfolders --limit 20
                        charkle semantic "极简陶瓷质感" --limit 12
                        charkle similar <asset-uuid> --limit 8
                        charkle inbox --suggest
                        charkle contact-sheet --inbox --out /tmp/inbox.jpg
                        charkle board patch <board-id> --add-note "配色已定稿"
                        charkle board export <board-id> --out /tmp/board.png --dark
                        charkle completions zsh
                        """
                    )
                }
            }
            .opacity(draftConfig.cliEnabled ? 1.0 : 0.72)

            SettingsSection("使用指南") {
                SettingsRow(
                    title: "已开放的外部 Agent 能力（20 项安全工具 · 4 套内置工作流）",
                    subtitle: "分页多维检索 / 语义与以图找图 / 联系表看图 / 读取 EXIF 与 AI 生图 Prompt / 情绪板色板与非重叠补丁 / 实时热刷新窗口"
                ) {
                    EmptyView()
                }

                InlineGuideDisclosure("不知道怎么跟 AI 开口？查看 3 条推荐对话示例") {
                    ForEach(Array(Self.samplePrompts.enumerated()), id: \.element.title) { index, item in
                        if index > 0 {
                            CharkleHairlineDivider()
                        }
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("“\(item.prompt)”")
                                    .font(.system(size: 11))
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

    private func mcpStatusSubtitle(enabled: Bool, helperReady: Bool) -> String {
        guard enabled else {
            return "已关闭 · 所有 MCP 客户端请求将被即时拦截（不影响终端 CLI）"
        }
        return helperReady
            ? "原生 Swift MCP 助手已就绪 · 20 项安全工具、动态 Resources 与 4 套 Prompts，零 Node/Python 依赖"
            : "当前运行在开发态，正式打包为 Charkle.app 后将自动内置原生 MCP 助手"
    }

    private func cliStatusSubtitle(enabled: Bool, linkStatus: SyncAndAIStore.CLILinkStatus) -> String {
        guard enabled else {
            return "已关闭 · 终端 charkle 读写命令将被即时拦截（不影响 MCP 客户端）"
        }
        switch linkStatus {
        case .linkedCurrent:
            return "已开放终端命令行 · ~/.local/bin/charkle 已指向当前版本，支持脚本与自动化调用"
        case .linkedStale:
            return "已开放终端命令行 · 检测到 ~/.local/bin/charkle 指向旧路径，建议点击下方「更新链接」"
        case .broken:
            return "已开放终端命令行 · ~/.local/bin/charkle 链接已失效，请点击下方「修复链接」"
        case .notLinked:
            return "已开放终端命令行 · 链接至 ~/.local/bin 后可在终端直接运行 charkle 命令"
        }
    }

    private func cliStatusColor(enabled: Bool, linkStatus: SyncAndAIStore.CLILinkStatus) -> Color {
        guard enabled else { return .secondary }
        switch linkStatus {
        case .linkedCurrent: return SettingsPalette.positiveInk(for: colorScheme)
        case .linkedStale, .broken: return SettingsPalette.warningInk(for: colorScheme)
        case .notLinked: return .secondary
        }
    }

    private func cliLinkRowSubtitle(_ status: SyncAndAIStore.CLILinkStatus) -> String {
        switch status {
        case .linkedCurrent:
            "已链接 ~/.local/bin/charkle 且与当前应用一致 · 支持交互排版与管道自动 JSON"
        case .linkedStale:
            "当前 ~/.local/bin/charkle 指向旧版或其他位置 · 点击右侧按钮即可更新到当前应用"
        case .broken:
            "~/.local/bin/charkle 软链接目标不存在 · 点击右侧按钮重新链接"
        case .notLinked:
            "尚未链接到 ~/.local/bin · 链接后可在终端直接运行 charkle doctor / overview / search"
        }
    }

    private func cliLinkRowColor(_ status: SyncAndAIStore.CLILinkStatus) -> Color {
        switch status {
        case .linkedCurrent: SettingsPalette.positiveInk(for: colorScheme)
        case .linkedStale, .broken: SettingsPalette.warningInk(for: colorScheme)
        case .notLinked: .secondary
        }
    }

    private func cliLinkButtonTitle(_ status: SyncAndAIStore.CLILinkStatus) -> String {
        switch status {
        case .linkedCurrent: "重新链接"
        case .linkedStale: "更新链接"
        case .broken: "修复链接"
        case .notLinked: "链接到本机"
        }
    }

    private func selfCheckSubtitleColor() -> Color {
        guard let passed = syncAndAI.externalAgentSelfCheckPassed else { return .secondary }
        return passed
            ? SettingsPalette.positiveInk(for: colorScheme)
            : SettingsPalette.warningInk(for: colorScheme)
    }
}

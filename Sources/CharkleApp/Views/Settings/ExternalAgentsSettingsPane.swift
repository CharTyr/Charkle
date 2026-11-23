import CharkleCore
import SwiftUI

/// Tab 7: 外部 Agent (Agents) — Native stdio MCP server & CLI setup with live readiness detection,
/// folded client snippets, and copyable natural-language prompt examples.
public struct ExternalAgentsSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let syncAndAI: SyncAndAIStore

    @State private var draftConfig: ExternalAgentConfig = ExternalAgentConfig()

    private static let samplePrompts: [(title: String, prompt: String)] = [
        ("找参考图并建情绪板", "帮我从 Charkle 素材库里挑 10 张温暖胶片质感、偏奶油色调的咖啡馆参考图，生成一块名为「早秋咖啡馆视觉」的情绪板。"),
        ("快速整理收件箱", "帮我看看 Charkle 收件箱里未整理的素材，按画面风格和内容建议归档到现有文件夹，并补齐统一标签。"),
        ("提取情绪板色板给开发", "读取我在 Charkle 里名为「品牌改版」的情绪板，导出主色板 HEX 和各分区批注，帮我整理成设计变量表。")
    ]

    public init(syncAndAI: SyncAndAIStore) {
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        let helperPath = syncAndAI.resolvedHelperCLIPath()
        let helperReady = syncAndAI.isBundledHelperAvailable
        let cliLinked = syncAndAI.isCLILinkedInLocalBin
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

        VStack(alignment: .leading, spacing: 22) {
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
                    subtitle: cliStatusSubtitle(enabled: draftConfig.cliEnabled, cliLinked: cliLinked),
                    subtitleColor: !draftConfig.cliEnabled
                        ? .secondary
                        : (cliLinked ? SettingsPalette.positiveInk(for: colorScheme) : .secondary)
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

                    InlineGuideDisclosure("数据安全如何保障？") {
                        SettingsGuideStep(
                            "1",
                            title: "MCP 与 CLI 独立管控，关闭即刻生效",
                            detail: "可按需只保留其中一项服务；关闭任意开关后，对应通道的新请求会立即被拦截。"
                        )
                        SettingsGuideStep(
                            "2",
                            title: "永不开放公网或局域网端口",
                            detail: "所有调用均通过本机标准输入输出（stdio）或本地 CLI 与数据库通信，外部网络无法访问。"
                        )
                        SettingsGuideStep(
                            "3",
                            title: "永不允许彻底删除素材",
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
                    subtitle: "在终端执行一行命令即可将 Charkle 注册为 MCP 工具"
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

                InlineGuideDisclosure("查看完整命令与验证方式") {
                    SettingsCodeSnippet(claudeCodeCmd)
                    SettingsGuideStep(
                        "1",
                        title: "在终端粘贴运行上方命令，完成后重启 Claude Code 对话",
                        detail: "输入「看看我的 Charkle 素材库概览」即可验证连通。"
                    )
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "Cursor / Antigravity / Codex",
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
                    subtitle: cliLinked
                        ? "已安装于 ~/.local/bin/charkle · 支持脚本与非 MCP 代理调用"
                        : "尚未链接到 ~/.local/bin · 链接后可在终端直接运行 charkle overview / search",
                    subtitleColor: cliLinked ? SettingsPalette.positiveInk(for: colorScheme) : .secondary
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

                        Button(cliLinked ? "重新链接" : "链接到本机") {
                            syncAndAI.installCLIInLocalBin()
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }

                InlineGuideDisclosure("常用命令行示例") {
                    SettingsCodeSnippet(
                        """
                        charkle status
                        charkle overview --json
                        charkle search "暖调陶艺" --limit 20
                        charkle contact-sheet --query "海报"
                        charkle board export <board-id> --json
                        """
                    )
                }
            }
            .opacity(draftConfig.cliEnabled ? 1.0 : 0.72)

            SettingsSection("使用指南") {
                SettingsRow(
                    title: "已开放的外部 Agent 能力",
                    subtitle: "视觉联系表直接看图选材 · 读取情绪板与主色板 HEX · 批量打标归档与生成画布并实时热刷新窗口"
                ) {
                    EmptyView()
                }

                InlineGuideDisclosure("不知道怎么跟 AI 开口？查看 3 条推荐对话示例") {
                    ForEach(Self.samplePrompts, id: \.title) { item in
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
            ? "原生 Swift MCP 助手已就绪 · 仅本机 stdio 通信，零 Node/Python 依赖，不开放任何网络端口"
            : "当前运行在开发态，正式打包为 Charkle.app 后将自动内置原生 MCP 助手"
    }

    private func cliStatusSubtitle(enabled: Bool, cliLinked: Bool) -> String {
        guard enabled else {
            return "已关闭 · 终端 charkle 读写命令将被即时拦截（不影响 MCP 客户端）"
        }
        return cliLinked
            ? "已开放终端命令行 · 已链接 ~/.local/bin/charkle，支持脚本与自动化调用"
            : "已开放终端命令行 · 链接至 ~/.local/bin 后可在终端直接运行 charkle 命令"
    }
}

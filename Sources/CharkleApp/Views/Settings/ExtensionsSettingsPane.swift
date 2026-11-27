import AppKit
import CharkleCanvas
import SwiftUI

/// Tab 8: 插件与扩展 (Extensions) — native integration hub for Charkle's Safari & Chrome
/// browser extensions (including one-click X Bookmarks & Xiaohongshu Collection batch import)
/// plus the bundled Figma / FigJam Bridge plugin.
public struct ExtensionsSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore

    @State private var revealToken: Bool = false

    public init(coordinator: AppCoordinatorStore, syncAndAI: SyncAndAIStore) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
    }

    private var bridge: ExtensionBridgeController {
        CharkleRuntime.shared.extensionBridge
    }

    private var maskedToken: String {
        let raw = bridge.accessToken
        guard raw.count > 10 else { return String(repeating: "•", count: max(8, raw.count)) }
        return "\(raw.prefix(6))••••••••••••\(raw.suffix(4))"
    }

    public var body: some View {
        let pluginDir = FigmaBridgeExporter.bundledPluginDirectoryURL()
        let manifestURL = pluginDir?.appending(path: "manifest.json")
        let manifestPath = manifestURL?.path

        let extDir = ExtensionBridgeController.bundledBrowserExtensionDirectoryURL()
        let extManifestURL = extDir?.appending(path: "manifest.json")
        let safariEmbedded = ExtensionBridgeController.isSafariExtensionEmbedded()

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("浏览器扩展（Safari 与 Chrome）") {
                SettingsRow(
                    title: "桌面端本地连接桥接",
                    subtitle: bridge.isRunning
                        ? (bridge.allowLocalAutoPair
                            ? "已就绪，本机 Safari / Chrome 扩展启用后自动直连"
                            : "运行中：\(bridge.baseURL)（手动令牌校验，仅限本机访问）")
                        : (bridge.lastError ?? "已关闭，开启后可供 Safari 与 Chrome 扩展连接素材库"),
                    subtitleColor: bridge.isRunning
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : .secondary
                ) {
                    HStack(spacing: 10) {
                        SettingsStatusBadge(
                            bridge.isRunning ? "已就绪" : "已暂停",
                            tint: bridge.isRunning ? SettingsPalette.positiveInk(for: colorScheme) : .secondary
                        )
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { bridge.isEnabled },
                                set: { newVal in
                                    guard bridge.isEnabled != newVal else { return }
                                    bridge.isEnabled = newVal
                                    coordinator.showToast(
                                        newVal ? "已开启浏览器扩展本地桥接" : "已关闭浏览器扩展本地桥接",
                                        icon: "puzzlepiece.extension",
                                        tone: .success
                                    )
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "同机扩展自动免密配对",
                    subtitle: "仅允许本机浏览器扩展自动配对，拦截普通网页请求"
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { bridge.allowLocalAutoPair },
                            set: { newVal in
                                guard bridge.allowLocalAutoPair != newVal else { return }
                                bridge.allowLocalAutoPair = newVal
                                coordinator.showToast(
                                    newVal ? "已开启同机扩展自动免密配对" : "已切换为手动令牌校验",
                                    icon: "lock.shield",
                                    tone: .success
                                )
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!bridge.isEnabled)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "Safari 浏览器扩展",
                    subtitle: safariEmbedded
                        ? "已内置于 Charkle.app，启用后自动直连并批量导入 X 书签与小红书"
                        : "使用正式打包的 Charkle.app 即可自动注册原生 Safari 扩展"
                ) {
                    Button("打开 Safari 扩展设置") {
                        bridge.openSafariExtensionPreferences()
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }

                InlineGuideDisclosure("如何在 Safari 中启用") {
                    SettingsGuideStep(
                        "1",
                        title: "点击上方「打开 Safari 扩展设置」，或在 Safari 菜单栏进入「设置 → 扩展」"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "勾选左侧列表中的「Charkle」，并点击「始终允许在所有网站上」",
                        detail: "启用后点击工具栏图标即可连接；若未显示扩展，请在 Safari「开发」菜单开启「允许未签名的扩展」。"
                    )
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "Chrome / Arc / Edge / Brave 扩展",
                    subtitle: extManifestURL != nil
                        ? "已内置扩展目录，加载后自动直连，支持采集与 X / 小红书批量导入"
                        : "未在当前路径找到扩展目录，请运行 ./scripts/build-app.sh release 打包完整应用"
                ) {
                    if let extDir {
                        Button("在访达中定位扩展") {
                            NSWorkspace.shared.activateFileViewerSelecting([extManifestURL ?? extDir])
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }

                InlineGuideDisclosure("如何在 Chrome / Arc / Edge 中安装与批量导入收藏") {
                    SettingsGuideStep(
                        "1",
                        title: "在浏览器打开 chrome://extensions（Arc / Edge 同理），打开右上角「开发者模式」"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "点击「加载已解压的扩展程序」，选择 Charkle 内置的 BrowserExtension 文件夹"
                    )
                    SettingsGuideStep(
                        "3",
                        title: "安装后自动连接本机，在 X 书签或小红书收藏页即可批量导入",
                        detail: "支持增量滚动与跳过已导入条目，并拉取小红书多图与 3:4 封面。"
                    )
                }

                SettingsCardDivider()

                InlineGuideDisclosure("高级：查看本机服务地址与手动访问令牌") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本机服务地址")
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                Text(bridge.baseURL)
                                    .font(CharkleTheme.text(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button("复制地址") {
                                SettingsHelpers.copyToClipboard(
                                    bridge.baseURL,
                                    toast: "已复制扩展连接地址",
                                    syncAndAI: syncAndAI
                                )
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }

                        CharkleHairlineDivider()

                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本机访问令牌（仅关闭自动配对或手动调试时需要）")
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                Text(revealToken ? bridge.accessToken : maskedToken)
                                    .font(CharkleTheme.text(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Button(revealToken ? "隐藏" : "显示") {
                                    revealToken.toggle()
                                }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                                .fixedSize()

                                Button("复制令牌") {
                                    SettingsHelpers.copyToClipboard(
                                        bridge.accessToken,
                                        toast: "已复制本机扩展访问令牌",
                                        syncAndAI: syncAndAI
                                    )
                                }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                                .fixedSize()

                                Button("重置") {
                                    _ = bridge.regenerateToken()
                                    coordinator.showToast(
                                        bridge.allowLocalAutoPair
                                            ? "已重新生成令牌，本机扩展将在下次使用时自动更新配对"
                                            : "已重新生成扩展令牌，请在浏览器扩展中更新",
                                        icon: "key.fill",
                                        tone: .success
                                    )
                                }
                                .buttonStyle(SettingsSecondaryButtonStyle())
                                .fixedSize()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            SettingsSection("Figma 与 FigJam") {
                SettingsRow(
                    title: "Charkle → Figma / FigJam Bridge",
                    subtitle: manifestURL != nil
                        ? "已内置离线插件，无需 API 密钥，保留独立图层、原图与 GIF"
                        : "未在当前开发路径找到内置插件目录，请使用正式打包后的 Charkle.app",
                    subtitleColor: manifestURL != nil
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : SettingsPalette.warningInk(for: colorScheme)
                ) {
                    if let manifestURL {
                        Button("在访达中定位插件") {
                            NSWorkspace.shared.activateFileViewerSelecting([manifestURL])
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .fixedSize()
                    }
                }

                InlineGuideDisclosure("如何在 Figma 桌面端安装插件") {
                    SettingsGuideStep(
                        "1",
                        title: "打开 Figma 桌面端的任意 Design 或 FigJam 文件"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "在顶部菜单栏选择：Plugins → Development → Import plugin from manifest…"
                    )
                    SettingsGuideStep(
                        "3",
                        title: "选择 Charkle 内置的 manifest.json 即可完成安装",
                        detail: "复制下方路径后，在文件选择框按 ⇧⌘G 粘贴即可定位。"
                    )
                }

                if let manifestPath {
                    SettingsCardDivider()

                    SettingsRow(
                        title: "插件清单路径（manifest.json）",
                        subtitle: manifestPath
                    ) {
                        Button("复制路径") {
                            SettingsHelpers.copyToClipboard(
                                manifestPath,
                                toast: "已复制 Figma 插件 manifest.json 路径",
                                syncAndAI: syncAndAI
                            )
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "如何使用 .charkleboard 导出与导入",
                    subtitle: "保留图片、便签、区域分组、矢量色卡、连线箭头与手绘批注"
                ) {
                    EmptyView()
                }

                InlineGuideDisclosure("查看情绪板导入 Figma / FigJam 完整流程") {
                    SettingsGuideStep(
                        "1",
                        title: "在 Charkle 打开任意情绪板，点击底部或右侧检查器的「导出 → 导出至 Figma / FigJam」",
                        detail: "生成无损 .charkleboard 文件（大图自动切块，GIF 保留原文件）。"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "在 Figma / FigJam 中运行「Charkle → Figma Bridge」插件，拖入该文件",
                        detail: "导入后保留为可编辑的原生图层。"
                    )
                }
            }
        }
    }
}

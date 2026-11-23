import AppKit
import CharkleCanvas
import SwiftUI

/// Tab 8: 插件与扩展 (Extensions) — native integration hub surfacing the bundled
/// Figma / FigJam Bridge plugin with inline setup steps, plus a clean slot for future browser extensions.
public struct ExtensionsSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore

    public init(coordinator: AppCoordinatorStore, syncAndAI: SyncAndAIStore) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        let pluginDir = FigmaBridgeExporter.bundledPluginDirectoryURL()
        let manifestURL = pluginDir?.appending(path: "manifest.json")
        let manifestPath = manifestURL?.path

        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Figma 与 FigJam") {
                SettingsRow(
                    title: "Charkle → Figma / FigJam Bridge",
                    subtitle: manifestURL != nil
                        ? "已内置于 Charkle · 纯本地离线导入，无需 API 密钥，无损保留独立图层、原图像素与 GIF"
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

                InlineGuideDisclosure("如何在 Figma 桌面端导入（仅首次需要，3 步）") {
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
                        detail: "提示：点击下方「复制路径」后，在文件选择框按 ⇧⌘G 粘贴即可一步直达。"
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
                        detail: "Charkle 会生成一份无损 .charkleboard 打包文件（超大图片自动无损切块，GIF 保留原字节）。"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "在 Figma / FigJam 中运行「Charkle → Figma Bridge」插件，拖入该文件",
                        detail: "所有对象都会以原生可编辑图层落地画布，方便继续二次创作。"
                    )
                }
            }

            SettingsSection("浏览器扩展") {
                SettingsRow(
                    title: "Chrome / Arc / Safari 浏览器采集扩展",
                    subtitle: "规划中：支持右键存图、整页快照与 X / Pinterest 深度适配。当前推荐先用 ⌥⇧V 一键收藏剪贴板或直接拖图至顶部刘海浮窗"
                ) {
                    HStack(spacing: 8) {
                        Button("查看采集技巧") {
                            coordinator.selectedSettingsTab = .notchShelf
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()

                        SettingsStatusBadge("规划中", tint: .secondary)
                    }
                }
            }
        }
    }
}

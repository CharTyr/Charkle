import CharkleCore
import SwiftUI

/// Tab 4: 刘海浮窗 (Notch Shelf) — Dedicated control surface for Charkle's signature top-edge inspiration drop shelf.
public struct NotchShelfSettingsPane: View {
    public let coordinator: AppCoordinatorStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void

    public init(
        coordinator: AppCoordinatorStore,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("顶部灵感浮窗") {
                SettingsRow(
                    title: "启用屏幕顶部灵感浮窗",
                    subtitle: "在其他应用中拖起图片、链接或文件时，屏幕顶部自动滑出收纳区"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.notchShelfEnabled },
                        set: { coordinator.notchShelfEnabled = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "悬停顶部中央自动展开",
                    subtitle: "鼠标移至屏幕顶部刘海区域时轻滑唤出浮窗，快速查看最近素材或拖出使用"
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

                SettingsCardDivider()

                SettingsRow(
                    title: "默认收纳目标",
                    subtitle: "拖入浮窗或通过快捷键采集的新灵感默认落入此位置（也可在浮窗顶部随时切换）"
                ) {
                    Picker("", selection: Binding(
                        get: { coordinator.defaultNotchTargetMode },
                        set: { newMode in
                            coordinator.defaultNotchTargetMode = newMode
                            onSyncDefaultNotchTarget(newMode)
                        }
                    )) {
                        ForEach(NotchTargetMode.allCases, id: \.self) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 156)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "预览顶部浮窗效果",
                    subtitle: "立即在屏幕顶部展开刘海浮窗，体验收纳与快速拖出交互（快捷键 ⌥⇧S）"
                ) {
                    Button("预览顶部浮窗") {
                        onToggleNotchPreview()
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }

                InlineGuideDisclosure("跨应用拖图与「活跃情绪板」连采技巧") {
                    SettingsGuideStep(
                        "1",
                        title: "浏览器 / Figma / 访达直接往屏幕顶部甩",
                        detail: "无需切换回 Charkle 窗口，拖起图片时刘海浮窗会自动滑出接住素材。"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "锁定「当前活跃情绪板」，边逛网页边长出一块板",
                        detail: "在浮窗顶部切换目标为「活跃情绪板」，之后所有截图、剪贴板收藏和拖图都会自动同步追加进画布。"
                    )
                    SettingsGuideStep(
                        "3",
                        title: "反向拖出素材同样顺手",
                        detail: "悬停顶部唤出浮窗后，可将最近收藏或完整瀑布流中的参考图直接拖进 Figma、Keynote 或设计软件。"
                    )
                }
            }
        }
    }
}

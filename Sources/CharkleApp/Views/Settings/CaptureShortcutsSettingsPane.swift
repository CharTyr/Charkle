import SwiftUI

/// Tab 5: 采集与快捷键 (Capture & Shortcuts) — macOS Screen Recording permission guidance,
/// global hotkey toggle, and cleanly grouped shortcut tables.
public struct CaptureShortcutsSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let onSyncHotkeysEnabled: (Bool) -> Void

    @State private var hasScreenCapturePermission: Bool = ScreenCapturePermissionChecker.hasScreenRecordingAccess()

    public init(
        coordinator: AppCoordinatorStore,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void
    ) {
        self.coordinator = coordinator
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("系统权限与全局采集") {
                SettingsRow(
                    title: "屏幕录制权限",
                    subtitle: hasScreenCapturePermission
                        ? "已授权 · 可随时在其他应用中使用 ⌥⇧A 区域截图收入素材库"
                        : "需要授予屏幕录制权限，才能在任意应用中区域截图并直接入库",
                    subtitleColor: hasScreenCapturePermission
                        ? SettingsPalette.positiveInk(for: colorScheme)
                        : SettingsPalette.warningInk(for: colorScheme)
                ) {
                    HStack(spacing: 8) {
                        Button("重新检测") {
                            hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .fixedSize()

                        if !hasScreenCapturePermission {
                            Button("打开系统设置") {
                                _ = ScreenCapturePermissionChecker.requestAccessPromptIfNeeded()
                                ScreenCapturePermissionChecker.openSystemSettings()
                            }
                            .buttonStyle(SettingsPrimaryButtonStyle())
                            .fixedSize()
                        } else {
                            Button("系统设置") {
                                ScreenCapturePermissionChecker.openSystemSettings()
                            }
                            .buttonStyle(SettingsSecondaryButtonStyle())
                            .fixedSize()
                        }
                    }
                }

                if !hasScreenCapturePermission {
                    InlineGuideDisclosure("如何在系统设置中开启屏幕录制权限") {
                        SettingsGuideStep(
                            "1",
                            title: "点击上方「打开系统设置」直达「隐私与安全性 → 录屏与系统录音」"
                        )
                        SettingsGuideStep(
                            "2",
                            title: "在列表中找到 Charkle 并打开右侧开关",
                            detail: "若列表中暂未出现，可点击左下角「+」手动选择 /Applications/Charkle.app。"
                        )
                        SettingsGuideStep(
                            "3",
                            title: "按系统提示重新打开 Charkle 或点击「重新检测」即可生效"
                        )
                    }
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "启用系统全局快捷键",
                    subtitle: "在任意应用中通过 ⌥⇧A 区域截图、⌥⇧V 收藏剪贴板、⌥⇧S 展开刘海浮窗"
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
            }

            SettingsSection("全局采集快捷键") {
                shortcutRow("区域截图并收入目标", keys: "⌥ ⇧ A")
                SettingsCardDivider()
                shortcutRow("一键收藏当前剪贴板（含 X 推文与媒体）", keys: "⌥ ⇧ V")
                SettingsCardDivider()
                shortcutRow("展开 / 收起顶部灵感浮窗", keys: "⌥ ⇧ S")
            }

            SettingsSection("画廊与整理") {
                shortcutRow("快速预览素材 / 再按一次退出", keys: "Space")
                SettingsCardDivider()
                shortcutRow("快速跳转情绪板、文件夹或素材", keys: "⌘ J")
                SettingsCardDivider()
                shortcutRow("快速生成新情绪板", keys: "⌘ N")
                SettingsCardDivider()
                shortcutRow("展开 / 收起视觉与配色筛选条", keys: "⇧ ⌘ S")
                SettingsCardDivider()
                shortcutRow("收起 / 展开侧边栏为仅图标", keys: "⌘ \\")
                SettingsCardDivider()
                shortcutRow("收件箱快速归档到对应文件夹", keys: "1 – 9")
                SettingsCardDivider()
                shortcutRow("拷贝、剪切与粘贴移动素材", keys: "⌘ C / ⌘ X / ⌘ V")
            }

            SettingsSection("情绪板画布") {
                shortcutRow("顺时针 / 逆时针旋转 90°", keys: "R / ⇧ R")
                SettingsCardDivider()
                shortcutRow("水平 / 上下翻转素材", keys: "⇧ H / ⇧ V")
                SettingsCardDivider()
                shortcutRow("画布自由平移查看", keys: "鼠标中键拖拽")
                SettingsCardDivider()
                shortcutRow("画布撤销 / 重做", keys: "⌘ Z / ⇧ ⌘ Z")
            }
        }
        .onAppear {
            hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
        }
    }

    private func shortcutRow(_ description: String, keys: String) -> some View {
        HStack {
            Text(description)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
            Spacer()
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    SettingsPalette.subtleFill(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

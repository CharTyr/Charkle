import KeyboardShortcuts
import SwiftUI

/// Tab 5: 采集与快捷键 (Capture & Shortcuts) — macOS Screen Recording permission guidance,
/// live recordable global shortcuts via `KeyboardShortcuts.Recorder`, and crisp in-app shortcut tables.
public struct CaptureShortcutsSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme

    public let coordinator: AppCoordinatorStore
    public let onSyncHotkeysEnabled: (Bool) -> Void

    @State private var hasScreenCapturePermission: Bool = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
    @State private var captureAreaSummary: String = "⌥⇧A"
    @State private var collectClipboardSummary: String = "⌥⇧V"
    @State private var toggleNotchSummary: String = "⌥⇧S"

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
                        ? "已授权 · 可随时在其他应用中使用 \(captureAreaSummary) 区域截图收入素材库"
                        : "需要授予屏幕录制权限，才能在任意应用中区域截图并直接入库",
                    subtitleColor: hasScreenCapturePermission
                        ? CharkleTheme.positive(for: colorScheme)
                        : CharkleTheme.warning(for: colorScheme)
                ) {
                    HStack(spacing: 8) {
                        Button("重新检测") {
                            hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
                        }
                        .buttonStyle(.charkle(.standard, size: .sm))
                        .fixedSize()

                        if !hasScreenCapturePermission {
                            Button("打开系统设置") {
                                _ = ScreenCapturePermissionChecker.requestAccessPromptIfNeeded()
                                ScreenCapturePermissionChecker.openSystemSettings()
                            }
                            .buttonStyle(.charkle(.accent, size: .sm))
                            .fixedSize()
                        } else {
                            Button("系统设置") {
                                ScreenCapturePermissionChecker.openSystemSettings()
                            }
                            .buttonStyle(.charkle(.standard, size: .sm))
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
                    subtitle: "在任意应用中通过 \(captureAreaSummary) 区域截图、\(collectClipboardSummary) 收藏剪贴板、\(toggleNotchSummary) 展开刘海浮窗"
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

            SettingsSection("全局采集快捷键", caption: "点击右侧输入框即可录制自定义组合键") {
                recorderRow(
                    title: "区域截图并收入目标",
                    subtitle: "在任意应用中框选屏幕区域并直接归档到当前目标",
                    name: .captureArea
                )
                SettingsCardDivider()
                recorderRow(
                    title: "一键收藏当前剪贴板",
                    subtitle: "自动识别图片、网页、社交帖文与媒体链接",
                    name: .collectClipboard
                )
                SettingsCardDivider()
                recorderRow(
                    title: "展开 / 收起顶部灵感浮窗",
                    subtitle: "在任意应用顶部呼出刘海采集与最近素材",
                    name: .toggleNotchShelf
                )
                SettingsCardDivider()
                SettingsRow(
                    title: "恢复默认组合键",
                    subtitle: "将上方三项重置为 ⌥⇧A、⌥⇧V 与 ⌥⇧S"
                ) {
                    Button("恢复默认快捷键") {
                        GlobalHotkeyManager.resetDefaults()
                        refreshShortcutSummaries()
                        onSyncHotkeysEnabled(coordinator.globalHotkeysEnabled)
                        coordinator.showToast("已恢复默认全局快捷键", icon: "arrow.counterclockwise")
                    }
                    .buttonStyle(.charkle(.standard, size: .sm))
                    .fixedSize()
                }
            }

            SettingsSection("画廊与整理") {
                shortcutRow("快速预览素材 / 再按一次退出", keys: ["Space"])
                SettingsCardDivider()
                shortcutRow("快速跳转情绪板、文件夹或素材", keys: ["⌘", "J"])
                SettingsCardDivider()
                shortcutRow("快速生成新情绪板", keys: ["⌘", "N"])
                SettingsCardDivider()
                shortcutRow("展开 / 收起视觉与配色筛选", keys: ["⇧", "⌘", "S"])
                SettingsCardDivider()
                shortcutRow("收起 / 展开侧边栏为仅图标", keys: ["⌘", "\\"])
                SettingsCardDivider()
                shortcutRow("显示 / 隐藏右侧详情检查器", keys: ["⌥", "⌘", "I"])
                SettingsCardDivider()
                shortcutRow("收件箱快速归档到对应文件夹", keys: ["1 – 9"])
                SettingsCardDivider()
                shortcutRow("拷贝、剪切与粘贴移动素材", keys: ["⌘C", "⌘X", "⌘V"])
            }

            SettingsSection("情绪板画布") {
                shortcutRow("顺时针 / 逆时针旋转 90°", keys: ["R", "⇧R"])
                SettingsCardDivider()
                shortcutRow("水平 / 上下翻转素材", keys: ["⇧H", "⇧V"])
                SettingsCardDivider()
                shortcutRow("画布自由平移查看", keys: ["鼠标中键拖拽"])
                SettingsCardDivider()
                shortcutRow("画布撤销 / 重做", keys: ["⌘Z", "⇧⌘Z"])
            }
        }
        .onAppear {
            hasScreenCapturePermission = ScreenCapturePermissionChecker.hasScreenRecordingAccess()
            refreshShortcutSummaries()
        }
    }

    private func recorderRow(
        title: String,
        subtitle: String,
        name: KeyboardShortcuts.Name
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            KeyboardShortcuts.Recorder(for: name) { _ in
                handleShortcutRecorded()
            }
            .fixedSize()
            .opacity(coordinator.globalHotkeysEnabled ? 1.0 : 0.6)
        }
    }

    private func handleShortcutRecorded() {
        refreshShortcutSummaries()
        onSyncHotkeysEnabled(coordinator.globalHotkeysEnabled)
    }

    private func refreshShortcutSummaries() {
        captureAreaSummary = GlobalHotkeyManager.displayString(for: .captureArea, fallback: "未设置")
        collectClipboardSummary = GlobalHotkeyManager.displayString(for: .collectClipboard, fallback: "未设置")
        toggleNotchSummary = GlobalHotkeyManager.displayString(for: .toggleNotchShelf, fallback: "未设置")
    }

    private func shortcutRow(_ description: String, keys: [String]) -> some View {
        HStack(spacing: 12) {
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 10)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, keycap in
                    Text(keycap)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(CharkleTheme.secondaryInk(for: colorScheme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .frame(minWidth: 22)
                        .background(
                            CharkleTheme.surfaceSubtle(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    CharkleTheme.hairline(for: colorScheme),
                                    lineWidth: CharkleTheme.hairlineWidth
                                )
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

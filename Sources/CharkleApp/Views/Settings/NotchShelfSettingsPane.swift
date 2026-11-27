import CharkleCore
import SwiftUI

/// Tab 4: 刘海浮窗 (Notch Shelf) — Dedicated control surface for Charkle's signature top-edge inspiration drop shelf
/// and Ultra-Low-Resource Minimal Capture Mode.
public struct NotchShelfSettingsPane: View {
    public let coordinator: AppCoordinatorStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void
    public let onEnterMinimalCaptureMode: () -> Void

    public init(
        coordinator: AppCoordinatorStore,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in },
        onEnterMinimalCaptureMode: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
        self.onEnterMinimalCaptureMode = onEnterMinimalCaptureMode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("顶部灵感浮窗") {
                SettingsRow(
                    title: "启用屏幕顶部灵感浮窗",
                    subtitle: "拖起图片、链接或文件时，屏幕顶部自动展开收纳区"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.notchShelfEnabled },
                        set: { newVal in
                            guard coordinator.notchShelfEnabled != newVal else { return }
                            coordinator.notchShelfEnabled = newVal
                            coordinator.showToast(
                                newVal ? "已启用屏幕顶部灵感浮窗" : "已关闭屏幕顶部灵感浮窗",
                                icon: "macwindow",
                                tone: .success
                            )
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "悬停顶部中央自动展开",
                    subtitle: "光标移至屏幕顶部中央时自动展开，方便取用最近素材"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.notchHoverTriggerEnabled },
                        set: { newVal in
                            guard coordinator.notchHoverTriggerEnabled != newVal else { return }
                            coordinator.notchHoverTriggerEnabled = newVal
                            coordinator.showToast(
                                newVal ? "已开启悬停顶部自动展开" : "已关闭悬停顶部自动展开",
                                icon: "macwindow",
                                tone: .success
                            )
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!coordinator.notchShelfEnabled)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "托盘展开形态",
                    subtitle: coordinator.notchPresentationMode.settingsSubtitle
                ) {
                    Picker("", selection: Binding(
                        get: { coordinator.notchPresentationMode },
                        set: { newMode in
                            guard coordinator.notchPresentationMode != newMode else { return }
                            coordinator.notchPresentationMode = newMode
                            coordinator.showToast(
                                "刘海浮窗形态已切换为「\(newMode.shortLabel)」",
                                icon: "macwindow",
                                tone: .success
                            )
                        }
                    )) {
                        ForEach(NotchShelfPresentationMode.allCases, id: \.self) { mode in
                            Text(mode.shortLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 264)
                    .disabled(!coordinator.notchShelfEnabled)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "默认收纳目标",
                    subtitle: "拖入或快捷键采集的素材默认存入此位置，可在浮窗顶部切换"
                ) {
                    Picker("", selection: Binding(
                        get: { coordinator.defaultNotchTargetMode },
                        set: { newMode in
                            guard coordinator.defaultNotchTargetMode != newMode else { return }
                            coordinator.defaultNotchTargetMode = newMode
                            onSyncDefaultNotchTarget(newMode)
                            let targetName: String = switch newMode {
                            case .inbox: "收件箱"
                            case .folder: "文件夹"
                            case .activeMoodboard: "活跃情绪板"
                            }
                            coordinator.showToast(
                                "默认收纳目标已设为「\(targetName)」",
                                icon: "tray.and.arrow.down",
                                tone: .success
                            )
                        }
                    )) {
                        Text("收件箱").tag(NotchTargetMode.inbox)
                        Text("文件夹").tag(NotchTargetMode.folder)
                        Text("活跃情绪板").tag(NotchTargetMode.activeMoodboard)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 236)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "预览顶部浮窗效果",
                    subtitle: "展开顶部浮窗预览收纳与拖出交互（快捷键 \(GlobalHotkeyManager.displayString(for: .toggleNotchShelf, fallback: "⌥⇧S"))）"
                ) {
                    Button("预览顶部浮窗") {
                        onToggleNotchPreview()
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }

                InlineGuideDisclosure("跨应用拖图与连续采集说明") {
                    SettingsGuideStep(
                        "1",
                        title: "拖图至屏幕顶部快速收纳",
                        detail: "在浏览器、Figma 或访达中拖起图片，顶部浮窗将自动滑出接收。"
                    )
                    SettingsGuideStep(
                        "2",
                        title: "锁定活跃情绪板连续采集",
                        detail: "将浮窗目标设为「活跃情绪板」，截图、剪贴板与拖图会自动追加到画布。"
                    )
                    SettingsGuideStep(
                        "3",
                        title: "从顶部浮窗拖出素材",
                        detail: "展开浮窗后，可将参考图直接拖入 Figma、Keynote 等应用。"
                    )
                }
            }

            SettingsSection("最低资源占用模式（仅保留刘海采集）") {
                SettingsRow(
                    title: "立即进入极简刘海模式",
                    subtitle: "关闭主窗口并释放画廊缓存，仅保留菜单栏入口与顶部刘海采集"
                ) {
                    Button("进入极简模式") {
                        onEnterMinimalCaptureMode()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                    .fixedSize()
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "启动时直接进入极简刘海模式",
                    subtitle: "启动时不打开主窗口，仅驻留菜单栏与顶部刘海"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.launchInMinimalCaptureMode },
                        set: { newVal in
                            guard coordinator.launchInMinimalCaptureMode != newVal else { return }
                            coordinator.launchInMinimalCaptureMode = newVal
                            coordinator.showToast(
                                newVal ? "已开启启动时直接进入极简刘海模式" : "已关闭启动时进入极简刘海模式",
                                icon: "bolt.circle.fill",
                                tone: .success
                            )
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                SettingsCardDivider()

                SettingsRow(
                    title: "关闭主窗口时自动进入极简刘海模式",
                    subtitle: "关闭主窗口后自动释放画廊内存，点击菜单栏图标可恢复主窗口"
                ) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.enterMinimalModeOnWindowClose },
                        set: { newVal in
                            guard coordinator.enterMinimalModeOnWindowClose != newVal else { return }
                            coordinator.enterMinimalModeOnWindowClose = newVal
                            coordinator.showToast(
                                newVal ? "已开启关闭主窗自动转入极简模式" : "已关闭关闭主窗自动转入极简模式",
                                icon: "xmark.circle",
                                tone: .success
                            )
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }
}

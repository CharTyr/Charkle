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
                    subtitle: "在其他应用中拖起图片、链接或文件时，屏幕顶部自动滑出收纳区"
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
                    subtitle: "鼠标移至屏幕顶部刘海区域时轻滑唤出浮窗，快速查看最近素材或拖出使用"
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
                    subtitle: "拖入浮窗或通过快捷键采集的新灵感默认落入此位置（也可在浮窗顶部随时切换）"
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
                    subtitle: "立即在屏幕顶部展开刘海浮窗，体验收纳与快速拖出交互（快捷键 \(GlobalHotkeyManager.displayString(for: .toggleNotchShelf, fallback: "⌥⇧S"))）"
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

            SettingsSection("最低资源占用模式（仅保留刘海采集）") {
                SettingsRow(
                    title: "立即进入极简刘海模式",
                    subtitle: "关闭主窗口、释放全库画廊与大图缓存并隐藏程序坞图标，仅保留顶部刘海采集、最近素材快捷取用与菜单栏入口"
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
                    subtitle: "打开 Charkle 时不加载主工作台，静默驻留菜单栏与顶部刘海，随时可从菜单栏恢复主窗口"
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
                    subtitle: "点按主窗口左上角关闭按钮后自动释放画廊内存并转入极简采集态，点击菜单栏图标即可瞬间回到主窗"
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

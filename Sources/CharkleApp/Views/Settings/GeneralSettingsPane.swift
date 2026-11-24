import AppKit
import CharkleCore
import SwiftUI

/// Tab 1: 通用 (General) — Accent source strategy, App Icon switcher, default gallery layout preference,
/// and re-runnable onboarding guide.
public struct GeneralSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore

    private let appIconManager = CharkleAppIconManager.shared
    @State private var hoveredIconVariant: CharkleAppIconVariant? = nil

    public init(coordinator: AppCoordinatorStore, syncAndAI: SyncAndAIStore) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        let activeAccent = CharkleTheme.accent(for: colorScheme, source: coordinator.accentSource)
        let accentSoft = CharkleTheme.accentSoft(for: colorScheme, source: coordinator.accentSource)
        let accentBorder = CharkleTheme.accentBorder(for: colorScheme, source: coordinator.accentSource)
        let accentButtonFill = CharkleTheme.accentButtonFill(for: colorScheme, source: coordinator.accentSource)
        let accentButtonInk = CharkleTheme.accentButtonForeground(for: colorScheme, source: coordinator.accentSource)

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("外观与图标") {
                SettingsRow(
                    title: "强调色来源",
                    subtitle: coordinator.accentSource.subtitle
                ) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(accentSoft)
                                .frame(width: 22, height: 22)
                            Circle()
                                .fill(activeAccent)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: CharkleTheme.hairlineWidth)
                                )
                        }
                        .animation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion), value: coordinator.accentSource)
                        .help(coordinator.accentSource == .studio ? "当前：工作室钴蓝" : "当前：跟随 macOS 系统强调色")

                        CharkleSegmentedControl(
                            selection: Binding(
                                get: { coordinator.accentSource },
                                set: { coordinator.accentSource = $0 }
                            ),
                            options: CharkleAccentSource.allCases,
                            size: .regular,
                            fullWidth: false,
                            title: { $0.displayTitle }
                        )
                    }
                }

                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("应用图标")
                            .font(.system(size: 13, weight: .medium))
                        Text("切换 Charkle 在程序坞与切换器中的图标风格，点击立即生效。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        ForEach(CharkleAppIconVariant.allCases) { variant in
                            let selected = appIconManager.currentVariant == variant
                            let hovered = hoveredIconVariant == variant
                            let tileShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)

                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                    appIconManager.select(variant)
                                }
                                syncAndAI.errorMessage = nil
                                syncAndAI.statusMessage = "已切换应用图标为「\(variant.title)」"
                            } label: {
                                HStack(spacing: 11) {
                                    ZStack(alignment: .topTrailing) {
                                        if let img = appIconManager.previewImage(for: variant) {
                                            Image(nsImage: img)
                                                .resizable()
                                                .interpolation(.high)
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 46, height: 46)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                                .shadow(color: Color.black.opacity(0.14), radius: 5, y: 2)
                                        }
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(accentButtonInk, accentButtonFill)
                                                .offset(x: 4, y: -4)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(variant.title)
                                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                                            .foregroundStyle(.primary)
                                        Text(variant.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    selected
                                        ? accentSoft
                                        : (hovered ? SettingsPalette.subtleFill(for: colorScheme) : Color.clear),
                                    in: tileShape
                                )
                                .overlay(
                                    tileShape.strokeBorder(
                                        selected ? accentBorder : Color.clear,
                                        lineWidth: 0.75
                                    )
                                )
                                .contentShape(tileShape)
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredIconVariant = variant
                                } else if hoveredIconVariant == variant {
                                    hoveredIconVariant = nil
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                SettingsCardDivider()

                SettingsRow(
                    title: "画廊默认排布",
                    subtitle: "打开全部素材或文件夹时默认采用的浏览视图"
                ) {
                    Picker("", selection: Binding(
                        get: { coordinator.galleryLayoutMode },
                        set: { coordinator.galleryLayoutMode = $0 }
                    )) {
                        ForEach(GalleryLayoutMode.allCases, id: \.self) { mode in
                            Text(mode.localizedLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 312)
                }
            }

            SettingsSection("入门与帮助") {
                SettingsRow(
                    title: "快速上手引导",
                    subtitle: "重新配置素材库存储、刘海浮窗与录屏权限、AI 智能与外观偏好（每步均可跳过）"
                ) {
                    Button("重新查看") {
                        coordinator.closeSettings()
                        coordinator.presentOnboarding()
                    }
                    .buttonStyle(SettingsPrimaryButtonStyle())
                    .fixedSize()
                }
            }
        }
    }
}

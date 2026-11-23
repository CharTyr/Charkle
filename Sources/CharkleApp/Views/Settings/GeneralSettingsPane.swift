import AppKit
import CharkleCore
import SwiftUI

/// Tab 1: 通用 (General) — App Icon switcher, default gallery layout preference, and re-runnable onboarding guide.
public struct GeneralSettingsPane: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let syncAndAI: SyncAndAIStore

    private let appIconManager = CharkleAppIconManager.shared

    public init(coordinator: AppCoordinatorStore, syncAndAI: SyncAndAIStore) {
        self.coordinator = coordinator
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("外观与图标") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("应用图标")
                            .font(.system(size: 13, weight: .medium))
                        Text("切换 Charkle 在程序坞与切换器中的图标风格，点击立即生效。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        ForEach(CharkleAppIconVariant.allCases) { variant in
                            let selected = appIconManager.currentVariant == variant
                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                    appIconManager.select(variant)
                                }
                                syncAndAI.errorMessage = nil
                                syncAndAI.statusMessage = "已切换应用图标为「\(variant.title)」"
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack(alignment: .topTrailing) {
                                        if let img = appIconManager.previewImage(for: variant) {
                                            Image(nsImage: img)
                                                .resizable()
                                                .interpolation(.high)
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 52, height: 52)
                                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                                .shadow(color: Color.black.opacity(0.16), radius: 6, y: 3)
                                        }
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(
                                                    colorScheme == .dark ? Color.black : Color.white,
                                                    colorScheme == .dark ? Color.white : Color(charkleHex: "#18191D")
                                                )
                                                .offset(x: 5, y: -5)
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
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    selected
                                        ? Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06)
                                        : SettingsPalette.subtleFill(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            selected
                                                ? Color.primary.opacity(colorScheme == .dark ? 0.45 : 0.35)
                                                : SettingsPalette.border(for: colorScheme),
                                            lineWidth: selected ? 1.25 : 0.75
                                        )
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
                .padding(16)

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
                    .frame(width: 244)
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
                }
            }
        }
    }
}

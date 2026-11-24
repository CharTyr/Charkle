import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Calibrated Neutral Surfaces for the Settings Overlay

public enum SettingsPalette {
    public static func railBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#17181B") : Color(charkleHex: "#F0EFEA")
    }

    public static func contentBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#121316") : Color(charkleHex: "#F6F6F4")
    }

    public static func cardBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#1B1C20") : Color(charkleHex: "#FFFFFF")
    }

    public static func subtleFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
    }

    public static func sectionLabel(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.46) : Color.black.opacity(0.48)
    }

    public static func rowDivider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.065)
    }

    public static func border(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.08)
    }

    public static func positiveInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#4ADE80") : Color(charkleHex: "#15803D")
    }

    public static func warningInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#FBBF24") : Color(charkleHex: "#B45309")
    }

    public static func destructiveInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#F87171") : Color(charkleHex: "#DC2626")
    }
}

// MARK: - External Section Header + Rounded Card Container

public struct SettingsSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    public let title: String
    public let caption: String?
    private let content: Content

    public init(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SettingsPalette.sectionLabel(for: colorScheme))
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.sectionLabel(for: colorScheme).opacity(0.75))
                }
            }
            .padding(.horizontal, 2)

            SettingsCard {
                content
            }
        }
    }
}

public struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SettingsPalette.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: 0.75)
        )
    }
}

public struct SettingsCardDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(SettingsPalette.rowDivider(for: colorScheme))
            .frame(height: 0.75)
            .padding(.horizontal, 16)
    }
}

// MARK: - Clean Row & Inline Guide Disclosure

public struct SettingsRow<Control: View>: View {
    public let title: String
    public let subtitle: String?
    public let subtitleColor: Color?
    private let control: Control

    public init(
        title: String,
        subtitle: String? = nil,
        subtitleColor: Color? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(subtitleColor ?? .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// Quiet inline disclosure link (`如何开启 >`, `查看安装步骤 >`)
/// that keeps the default surface calm while offering step-by-step guidance right in context.
public struct InlineGuideDisclosure<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let title: String
    private let content: Content

    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(
                    isHovered || isExpanded
                        ? Color.primary.opacity(0.84)
                        : SettingsPalette.sectionLabel(for: colorScheme)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    isHovered
                        ? Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .padding(.horizontal, 6)
            .padding(.top, 0)
            .padding(.bottom, isExpanded ? 6 : 8)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    SettingsPalette.subtleFill(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(SettingsPalette.border(for: colorScheme).opacity(0.75), lineWidth: 0.75)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .transition(CharkleMotion.revealTransition(offsetY: -4, reduced: reduceMotion))
            }
        }
    }
}

public struct SettingsGuideStep: View {
    @Environment(\.colorScheme) private var colorScheme

    public let number: String
    public let title: String
    public let detail: String?

    public init(_ number: String, title: String, detail: String? = nil) {
        self.number = number
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .frame(width: 18, height: 18)
                .background(
                    colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.80),
                    in: Circle()
                )
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Monochrome High-Contrast Primary / Subtle Secondary / Soft Destructive Button Styles

public struct SettingsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color(charkleHex: "#111215") : Color.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .background(
                (colorScheme == .dark ? Color.white : Color(charkleHex: "#18191D"))
                    .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1.0) : 0.35),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: configuration.isPressed)
    }
}

public struct SettingsSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let fillOpacity: Double = colorScheme == .dark
            ? (configuration.isPressed ? 0.13 : 0.08)
            : (configuration.isPressed ? 0.09 : 0.05)
        let strokeOpacity: Double = colorScheme == .dark ? 0.12 : 0.10

        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.92 : 0.40))
            .padding(.horizontal, 12)
            .padding(.vertical, 6.5)
            .background(
                Color.primary.opacity(fillOpacity),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(strokeOpacity), lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: configuration.isPressed)
    }
}

public struct SettingsDestructiveButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let ink = SettingsPalette.destructiveInk(for: colorScheme)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink.opacity(isEnabled ? 1.0 : 0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 6.5)
            .background(
                ink.opacity(configuration.isPressed ? 0.16 : 0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ink.opacity(0.22), lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: configuration.isPressed)
    }
}

public struct SettingsStatusBadge: View {
    public let text: String
    public let tint: Color

    public init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(tint.opacity(0.12), in: Capsule(style: .continuous))
    }
}

/// Inline status/error feedback banner rendered inside Settings modal sheets so test-connection,
/// migration, and OAuth errors remain immediately visible instead of hiding behind the sheet.
public struct SettingsSheetFeedbackBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    public let syncAndAI: SyncAndAIStore

    public init(syncAndAI: SyncAndAIStore) {
        self.syncAndAI = syncAndAI
    }

    public var body: some View {
        if let err = syncAndAI.errorMessage, !err.isEmpty {
            bannerRow(text: err, isError: true) {
                syncAndAI.errorMessage = nil
            }
        } else if let status = syncAndAI.statusMessage, !status.isEmpty {
            bannerRow(text: status, isError: false) {
                syncAndAI.statusMessage = nil
            }
        }
    }

    private func bannerRow(text: String, isError: Bool, onDismiss: @escaping () -> Void) -> some View {
        let tint = isError
            ? SettingsPalette.destructiveInk(for: colorScheme)
            : SettingsPalette.positiveInk(for: colorScheme)
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.75)
        )
    }
}

public struct SettingsCodeSnippet: View {
    @Environment(\.colorScheme) private var colorScheme

    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

// MARK: - Shared Helpers

public enum SettingsHelpers {
    public static let gdirectTutorialURL = URL(
        string: "https://github.com/mizorewww/gdirect/blob/main/docs/configuration/google-cloud.md"
    )!

    public static let geminiKeyURL = URL(
        string: "https://aistudio.google.com/apikey"
    )!

    public static let typeSafeHomeURL = URL(
        string: "https://typesafe.ai"
    )!

    public static func relativeTimeText(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 15 { return "刚刚" }
        if elapsed < 60 { return "\(Int(elapsed)) 秒前" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }

    public static func copyToClipboard(_ text: String, toast: String, syncAndAI: SyncAndAIStore) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        syncAndAI.errorMessage = nil
        syncAndAI.statusMessage = toast
    }

    public static func pickLocalDirectory(initialPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择素材库保存文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let expanded = (initialPath as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    public static func presentOAuthSecretImporter(
        syncAndAI: SyncAndAIStore,
        autoSignInAfterImport: Bool = false,
        onComplete: (@MainActor () -> Void)? = nil
    ) {
        let panel = NSOpenPanel()
        panel.title = "选择 Google 登录凭据文件 (.json)"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                let ok = await syncAndAI.importGoogleOAuthSecret(from: url)
                if ok {
                    onComplete?()
                    if autoSignInAfterImport {
                        _ = await syncAndAI.signInGoogleDrive()
                    }
                }
            }
        }
    }

    @ViewBuilder
    public static func chatGPTBrandMark(size: CGFloat, color: Color) -> some View {
        let url = Bundle.module.url(forResource: "chatgpt-mark", withExtension: "svg")
            ?? Bundle.module.url(forResource: "chatgpt-mark", withExtension: "svg", subdirectory: "Icons")
        if let url, let nsImage = NSImage(contentsOf: url) {
            let _ = { nsImage.isTemplate = true }()
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(color)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}

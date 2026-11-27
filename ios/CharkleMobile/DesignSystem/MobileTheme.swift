import CharkleCore
import SwiftUI
import UIKit

/// Charkle Mobile Design System Tokens — strictly aligned with root `DESIGN.md`.
///
/// Enforces 90–95% neutral gallery canvas, Studio Cobalt accent (`#2A60E0` / `#5B8DEF`),
/// zero violet/neon gradients, 4pt spacing scale, and continuous concentric corners.
enum MobileTheme {
    static let studioAccentLightHex = "#2A60E0"
    static let studioAccentDarkHex = "#5B8DEF"
    static let studioAccentDarkFillHex = "#3A70E4"

    /// 10 calibrated low-saturation filter swatches from `DESIGN.md` §2.4.
    static let filterSwatches: [String] = [
        "#1E2024", "#5C6B73", "#3D5A80", "#4E7D96", "#6B8E76",
        "#D4A373", "#BA6B55", "#E5B243", "#C8B8A6", "#F0EEE9"
    ]

    /// Folder accent palette matching macOS / Windows neutral studio hues.
    static let folderPalette: [String] = [
        "#2A60E0", "#4E7D96", "#6B8E76", "#C98212",
        "#BA6B55", "#5C6B73", "#3D5A80", "#8A7968"
    ]

    static func galleryGround(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#141517") : Color(charkleHex: "#F6F6F5")
    }

    static func surfaceElevated(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#1E2025") : Color(charkleHex: "#FFFFFF")
    }

    static func surfaceSubtle(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#24272C") : Color(charkleHex: "#EDEDE9")
    }

    static func sidebarBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#17191D") : Color(charkleHex: "#F2F1EE")
    }

    static func inspectorBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#131519") : Color(charkleHex: "#F1F0EC")
    }

    static func inspectorFieldSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#16181D") : Color(charkleHex: "#F6F5F1")
    }

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    static func borderStrong(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14)
    }

    static func secondaryInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#A1A6B0") : Color(charkleHex: "#5C6069")
    }

    static func tertiaryInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#6E737D") : Color(charkleHex: "#8A8F99")
    }

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: studioAccentDarkHex) : Color(charkleHex: studioAccentLightHex)
    }

    static func accentSoft(for scheme: ColorScheme) -> Color {
        accent(for: scheme).opacity(scheme == .dark ? 0.16 : 0.11)
    }

    static func accentButtonFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: studioAccentDarkFillHex) : Color(charkleHex: studioAccentLightHex)
    }

    static func positive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#34C769") : Color(charkleHex: "#249A4B")
    }

    static func warning(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#F2B23E") : Color(charkleHex: "#C98212")
    }

    static func destructive(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#F2584D") : Color(charkleHex: "#D93B30")
    }

    static func ambientTint(from hex: String?, scheme: ColorScheme) -> Color {
        guard let hex else { return .clear }
        return Color(charkleHex: hex).opacity(scheme == .dark ? 0.10 : 0.06)
    }

    // MARK: - Desktop-Parity Color & Media Formatting Helpers

    /// Normalizes a user-entered hex string (`#RGB`, `RGB`, `#RRGGBB`, or `RRGGBB`) into uppercase `#RRGGBB`.
    nonisolated static func normalizedHex(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        if cleaned.count == 6 {
            return "#\(cleaned)"
        }
        if cleaned.count == 3 {
            let expanded = cleaned.map { "\($0)\($0)" }.joined()
            return "#\(expanded)"
        }
        return nil
    }

    /// Converts a SwiftUI `Color` into an uppercase sRGB `#RRGGBB` hex string.
    static func hexString(from color: Color) -> String? {
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(
                format: "#%02X%02X%02X",
                Int((max(0, min(1, r)) * 255).rounded()),
                Int((max(0, min(1, g)) * 255).rounded()),
                Int((max(0, min(1, b)) * 255).rounded())
            )
        }
        guard let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = uiColor.cgColor.converted(to: srgbSpace, intent: .defaultIntent, options: nil),
              let comps = converted.components,
              comps.count >= 3 else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int((max(0, min(1, comps[0])) * 255).rounded()),
            Int((max(0, min(1, comps[1])) * 255).rounded()),
            Int((max(0, min(1, comps[2])) * 255).rounded())
        )
    }

    /// Semantic CIELAB tolerance tier matching macOS `CharkleColorFilterPopover`.
    static func colorToleranceLabel(_ value: Double) -> String {
        if value <= 20 { return "极近" }
        if value <= 34 { return "相近" }
        return "宽泛"
    }

    /// SF Symbol matching macOS `MainWindowView.mediaKindSymbol(for:)`.
    static func mediaKindSymbol(for kind: MediaKind) -> String {
        switch kind {
        case .image: "photo"
        case .animatedImage: "photo.stack"
        case .video: "video"
        case .webBookmark: "globe"
        case .document: "doc.text"
        case .designFile: "square.on.circle"
        case .audio: "waveform"
        case .model3D: "cube"
        }
    }

    enum Radius {
        static let dockOuter: CGFloat = 20
        static let dockInner: CGFloat = 12
        static let settingsOuter: CGFloat = 14
        static let settingsInner: CGFloat = 8
        static let cardOuter: CGFloat = 12
        static let cardInnerBadge: CGFloat = 6
        static let chip: CGFloat = 8
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }
}

/// Role-mapped motion curves from `DESIGN.md` §6.2.
enum MobileMotion {
    static let enterSm = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    static let enterMd = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    static let settleStrong = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    static let exitSm = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.13)
    static let drawerEase = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.30)
    static let hoverPress = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)
    static let gestureSpring = Animation.spring(duration: 0.36, bounce: 0.10)
    static let reducedFade = Animation.easeOut(duration: 0.15)

    static func accessible(_ animation: Animation, reduced: Bool) -> Animation {
        reduced ? reducedFade : animation
    }
}

extension Color {
    nonisolated init(charkleHex raw: String) {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var hexValue: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&hexValue) else {
            self = Color(.systemGray)
            return
        }
        let r = Double((hexValue >> 16) & 0xFF) / 255.0
        let g = Double((hexValue >> 8) & 0xFF) / 255.0
        let b = Double(hexValue & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

/// Restrained floating glass surface strictly for overlays above media/canvas:
/// - iOS 26+: real native Apple Liquid Glass (`.glassEffect(.regular.interactive(), in: shape)`),
///   matching macOS `charkleLiquidGlass` and iOS system Photos / TabView chrome.
/// - iOS 18–25: calibrated `.ultraThinMaterial` with specular rim highlight.
/// - Reduce Transparency: crisp high-contrast solid surface.
struct CharkleFloatingSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(MobileTheme.surfaceElevated(for: colorScheme), in: shape)
                .overlay(shape.strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 1))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.08), radius: 12, y: 4)
        } else if #available(iOS 26.0, *) {
            let base: Glass = tint != nil ? Glass.regular.tint(tint) : Glass.regular
            let resolved: Glass = interactive ? base.interactive() : base
            content
                .glassEffect(resolved, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.08)).allowsHitTesting(false)
                    }
                }
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.24 : 0.80),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.08), radius: 14, y: 5)
        }
    }
}

struct CharkleGlassCluster<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

struct CharkleScrollEdgeSoftModifier: ViewModifier {
    let edges: Edge.Set

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            content
        }
    }
}

/// Resigns active first responder across the key window (including sibling overlays such as
/// the bottom Liquid Glass search capsule or pinned sidebar/picker search bars) the instant
/// a user begins dragging a scrollable surface.
@MainActor
enum MobileKeyboard {
    private(set) static var dismissSequence: UInt64 = 0

    static func dismiss() {
        dismissSequence &+= 1
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct CharkleDismissKeyboardOnScrollModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.immediately)
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting {
                    MobileKeyboard.dismiss()
                }
            }
    }
}

extension View {
    func charkleFloatingCapsule(interactive: Bool = true, tint: Color? = nil) -> some View {
        modifier(CharkleFloatingSurfaceModifier(shape: Capsule(), interactive: interactive, tint: tint))
    }

    func charkleFloatingCircle(interactive: Bool = true, tint: Color? = nil) -> some View {
        modifier(CharkleFloatingSurfaceModifier(shape: Circle(), interactive: interactive, tint: tint))
    }

    func charkleFloatingCard(
        cornerRadius: CGFloat = MobileTheme.Radius.dockOuter,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(
            CharkleFloatingSurfaceModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                interactive: interactive,
                tint: tint
            )
        )
    }

    func charkleScrollEdgeSoft(for edges: Edge.Set = .top) -> some View {
        modifier(CharkleScrollEdgeSoftModifier(edges: edges))
    }

    func charkleDismissKeyboardOnScroll() -> some View {
        modifier(CharkleDismissKeyboardOnScrollModifier())
    }
}

struct MobileTactileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(MobileMotion.accessible(MobileMotion.hoverPress, reduced: reduceMotion), value: configuration.isPressed)
    }
}

enum MobileHaptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    static func light() {
        lightGenerator.impactOccurred()
    }

    static func medium() {
        mediumGenerator.impactOccurred()
    }

    static func selection() {
        selectionGenerator.selectionChanged()
    }

    static func success() {
        notificationGenerator.notificationOccurred(.success)
    }

    static func warning() {
        notificationGenerator.notificationOccurred(.warning)
    }

    static func error() {
        notificationGenerator.notificationOccurred(.error)
    }
}

enum MobileFormatters {
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    static func relativeDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Shared waterfall masonry geometry aligned 1:1 with desktop `MasonryLayoutEngine`.
enum MobileMasonryLayout {
    static let desktopAspectRange: ClosedRange<CGFloat> = 0.55...2.15

    /// Mirrors `MasonryLayoutEngine.effectiveAspectRatio(for:clampedRange:)` from desktop `CharkleCanvas`,
    /// with an orientation-mismatch guard when a decoded thumbnail reveals real pixel proportions.
    static func effectiveAspectRatio(
        for asset: AssetRecord,
        loadedImage: UIImage? = nil,
        clampedRange: ClosedRange<CGFloat> = desktopAspectRange
    ) -> CGFloat {
        let metadataRatio: CGFloat = switch asset.mediaKind {
        case .audio:
            1.55
        case .webBookmark:
            if asset.isSocialPost {
                asset.pixelWidth > 0 && asset.pixelHeight > 0
                    ? CGFloat(asset.aspectRatio)
                    : (asset.richMetadata?.socialPost?.platform == .xiaohongshu
                        ? 0.625
                        : (asset.richMetadata?.socialPost?.platform.isVideoPlatform == true ? 1.26 : 1.12))
            } else if asset.isGitHubRepo {
                asset.pixelWidth > 0 && asset.pixelHeight > 0 ? CGFloat(asset.aspectRatio) : 1.32
            } else {
                asset.pixelWidth > 0 && asset.pixelHeight > 0 ? CGFloat(asset.aspectRatio) : 1.6
            }
        case .document:
            asset.fileName.lowercased().hasSuffix(".swatch") ? 1.0 : 0.84
        case .model3D:
            asset.pixelWidth > 0 && asset.pixelHeight > 0 ? CGFloat(asset.aspectRatio) : 1.0
        default:
            CGFloat(asset.aspectRatio)
        }

        let resolvedRaw: CGFloat
        if let loadedImage, loadedImage.size.width > 0, loadedImage.size.height > 0 {
            let imgRatio = loadedImage.size.width / loadedImage.size.height
            let missingMeta = asset.pixelWidth <= 0 || asset.pixelHeight <= 0
            let orientationMismatch = (imgRatio > 1.06 && metadataRatio < 0.94)
                || (imgRatio < 0.94 && metadataRatio > 1.06)
            if missingMeta || orientationMismatch {
                resolvedRaw = imgRatio
            } else {
                resolvedRaw = metadataRatio
            }
        } else {
            resolvedRaw = metadataRatio
        }

        return max(clampedRange.lowerBound, min(clampedRange.upperBound, resolvedRaw))
    }

    static func resolvedColumnCount(for width: CGFloat, isCompact: Bool, override: Int?) -> Int {
        let minCols = isCompact ? 1 : 2
        let maxCols = isCompact ? 5 : 7
        if let override {
            return max(minCols, min(maxCols, override))
        }
        if width >= 1_100 { return 5 }
        if width >= 820 { return 4 }
        if width >= 580 { return 3 }
        return 2
    }

    static func adaptiveSpacing(for colCount: Int, isCompact: Bool) -> CGFloat {
        switch colCount {
        case 1: return 12
        case 2: return isCompact ? 8 : 12
        case 3: return isCompact ? 5 : 10
        case 4: return isCompact ? 3 : 8
        default: return 2
        }
    }

    static func adaptiveCornerRadius(for colCount: Int) -> CGFloat {
        switch colCount {
        case 1, 2: return MobileTheme.Radius.cardOuter
        case 3: return 9
        case 4: return 6
        default: return 3
        }
    }

    static func distributeIntoColumns(_ items: [AssetRecord], count: Int) -> [[AssetRecord]] {
        let safeCount = max(1, count)
        var columns = Array(repeating: [AssetRecord](), count: safeCount)
        var heights = Array(repeating: Double(0), count: safeCount)

        for asset in items {
            var shortestIdx = 0
            var shortestHeight = heights[0]
            if safeCount > 1 {
                for idx in 1..<safeCount where heights[idx] < shortestHeight - 0.005 {
                    shortestHeight = heights[idx]
                    shortestIdx = idx
                }
            }
            columns[shortestIdx].append(asset)
            let clampedRatio = Double(effectiveAspectRatio(for: asset))
            heights[shortestIdx] += (1.0 / clampedRatio) + 0.08
        }
        return columns
    }
}

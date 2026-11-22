import CharkleCanvas
import SwiftUI

/// Gallery-First neutral surfaces, Kubai Tip 004 continuous concentric radii,
/// and Restrained Apple Liquid Glass tokens (macOS 26+ native with calibrated macOS 15
/// and Reduce Transparency fallbacks).
public enum CharkleTheme {
    // MARK: - Gallery-First Neutral Surfaces (Zero Violet / Neon AI Slop)

    public static func galleryGround(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#141517") : Color(charkleHex: "#F6F6F5")
    }

    public static func surfaceElevated(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#1E2024") : Color(charkleHex: "#FFFFFF")
    }

    public static func surfaceSubtle(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#24272C") : Color(charkleHex: "#EDEDE9")
    }

    public static func inspectorBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(charkleHex: "#191B1F") : Color(charkleHex: "#FAF9F7")
    }

    public static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    public static func secondaryInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.64) : Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.72)
    }

    /// Ultra-subtle low-saturation ambient tint for Quick Look & Single Asset Inspector (never pollutes artwork color).
    public static func ambientTint(from hex: String?, scheme: ColorScheme) -> Color {
        guard let hex else { return .clear }
        return Color(charkleHex: hex).opacity(scheme == .dark ? 0.10 : 0.06)
    }

    // MARK: - Continuous Concentric Corner Tokens (Kubai Tip 004, 4pt Grid)

    public enum Radius {
        public static let dockOuter: CGFloat = 20
        public static let dockPadding: CGFloat = 8
        public static let dockInner: CGFloat = concentricInner(outer: dockOuter, padding: dockPadding) // 12

        public static let cardOuter: CGFloat = 12
        public static let cardBadgePadding: CGFloat = 6
        public static let cardInnerBadge: CGFloat = concentricInner(outer: cardOuter, padding: cardBadgePadding) // 6

        public static let settingsOuter: CGFloat = 14
        public static let settingsPadding: CGFloat = 6
        public static let settingsInner: CGFloat = concentricInner(outer: settingsOuter, padding: settingsPadding) // 8

        public static let popoverOuter: CGFloat = 16
        public static let popoverInner: CGFloat = 10

        public static let chip: CGFloat = 8

        public static func concentricInner(outer: CGFloat, padding: CGFloat) -> CGFloat {
            max(4, outer - padding)
        }
    }

    // MARK: - Spacing Grid (4pt increments)

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
    }
}

// MARK: - Restrained Apple Liquid Glass System

public enum CharkleGlassVariant: Sendable {
    case regular
    case clear
    case darkNotch
}

public struct CharkleGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

public struct CharkleLiquidGlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private let variant: CharkleGlassVariant
    private let shape: S
    private let tint: Color?
    private let interactive: Bool

    public init(
        variant: CharkleGlassVariant = .regular,
        shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) {
        self.variant = variant
        self.shape = shape
        self.tint = tint
        self.interactive = interactive
    }

    public func body(content: Content) -> some View {
        if reduceTransparency {
            // Accessibility Reduce Transparency: crisp high-contrast solid surface
            let solidBg: Color = switch variant {
            case .darkNotch: Color(charkleHex: "#121316")
            case .regular, .clear: CharkleTheme.surfaceElevated(for: colorScheme)
            }
            let stroke: Color = variant == .darkNotch
                ? Color.white.opacity(0.16)
                : CharkleTheme.hairline(for: colorScheme)
            content
                .background(solidBg, in: shape)
                .overlay(shape.strokeBorder(stroke, lineWidth: 1))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.10), radius: 14, y: 6)
        } else if variant == .darkNotch {
            // Notch Shelf dark glass expansion capsule (calibrated against physical MacBook bezel;
            // gentle dual-layer shadow fully contained inside the oversized transparent NSPanel so it never clips).
            if #available(macOS 26, *) {
                let glass = Glass.regular.tint(Color(charkleHex: "#0B0C0F").opacity(0.88))
                content
                    .glassEffect(interactive ? glass.interactive() : glass, in: shape)
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.0), Color.white.opacity(0.14), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                    .shadow(color: Color.black.opacity(0.24), radius: 22, y: 10)
            } else {
                content
                    .background(Color(charkleHex: "#0E1014").opacity(0.92), in: shape)
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.02), Color.white.opacity(0.14), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 6, y: 2)
                    .shadow(color: Color.black.opacity(0.28), radius: 22, y: 10)
            }
        } else if #available(macOS 26, *) {
            let base: Glass = variant == .clear ? .clear : .regular
            let tinted: Glass = tint != nil ? base.tint(tint) : base
            let finalGlass: Glass = interactive ? tinted.interactive() : tinted
            content
                .glassEffect(finalGlass, in: shape)
        } else {
            // Calibrated macOS 15 fallback with Kubai 010 bright specular rim highlight
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.08)).allowsHitTesting(false)
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.24 : 0.85),
                                Color.white.opacity(colorScheme == .dark ? 0.05 : 0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.10), radius: 16, y: 6)
        }
    }
}

public struct CharkleScrollEdgeModifier: ViewModifier {
    private let edges: Edge.Set

    public init(edges: Edge.Set = .top) {
        self.edges = edges
    }

    public func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            content
        }
    }
}

public extension View {
    func charkleLiquidGlass<S: InsettableShape>(
        _ variant: CharkleGlassVariant = .regular,
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(CharkleLiquidGlassModifier(variant: variant, shape: shape, tint: tint, interactive: interactive))
    }

    func charkleScrollEdgeSoft(for edges: Edge.Set = .top) -> some View {
        modifier(CharkleScrollEdgeModifier(edges: edges))
    }
}

// MARK: - Wrapping Flow Layout (for Tags, AI Suggestions, gdirect Account & Endpoint Chips)

public nonisolated struct CharkleFlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if cursorX > 0 && cursorX + size.width > maxWidth {
                cursorX = 0
                cursorY += rowHeight + lineSpacing
                rowHeight = 0
            }
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: cursorY + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var cursorX = bounds.minX
        var cursorY = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if cursorX > bounds.minX && cursorX + size.width > bounds.maxX {
                cursorX = bounds.minX
                cursorY += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: cursorX, y: cursorY), proposal: ProposedViewSize(size))
            cursorX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

import SwiftUI

/// Role-mapped motion token registry for Charkle (easing curves, drag ripple, UI continuity,
/// and trigger-origin popovers).
///
/// Every transition in Charkle uses one of these role-mapped curves rather than default `.easeInOut`
/// or `.linear` for spatial movement.
public enum CharkleMotion {
    // MARK: - Role-Mapped Timing Curves

    /// Strong `ease-out` (0.23, 1, 0.32, 1) — Small UI entering (toasts, tooltips, menus, popovers).
    public static let enterSm = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)

    /// Strong `ease-out` (0.23, 1, 0.32, 1) — Medium UI entering (inspector panels, dialogs).
    public static let enterMd = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)

    /// Strong `ease-out` (0.23, 1, 0.32, 1) — Large surfaces entering (sheets, studio transitions; strictly ≤300ms).
    public static let enterLg = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)

    /// Crisp `ease-out-strong` (0.22, 1, 0.36, 1) — Active pills, toggles, selected filter chips, stepped reveals.
    public static let settleStrong = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)

    /// Crisp `ease-out` (0.23, 1, 0.32, 1) — Small UI leaving (instant start, shorter than enter — never ease-in).
    public static let exitSm = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.13)

    /// Crisp `ease-out` (0.23, 1, 0.32, 1) — Medium UI leaving (instant start, always shorter than enter).
    public static let exitMd = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.17)

    /// Confident `ease-in-out` (0.77, 0, 0.175, 1) — Elements already on screen moving/resizing (segmented indicator, reflow).
    public static let moveOnScreen = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.24)

    /// Drawer & side-panel slide curve (0.32, 0.72, 0, 1) — smooth sheet & inspector deceleration.
    public static let drawerEase = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.30)

    /// `--ease-overshoot` (0.34, 1.56, 0.64, 1) — Tiny ≤64px confirmations ONLY (checkbox tick, rating star, badge pop).
    public static let microOvershoot = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.26)

    /// Fluid interruptible hardware morph spring for MacBook Notch Shelf expand / collapse / full-gallery reveal.
    public static let notchMorphSpring = Animation.spring(duration: 0.42, bounce: 0.08)

    /// Momentum spring for drag release, Quick Look zoom-to-card, and physical gesture hand-off.
    public static let gestureSpring = Animation.spring(duration: 0.36, bounce: 0.10)

    /// Critically damped UI spring for responsive state morphs without bounce.
    public static let uiSpring = Animation.spring(duration: 0.28, bounce: 0.0)

    /// Fast micro-tactile hover & pointer-down feedback (never animate layout on hover!).
    public static let hoverPress = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)

    /// Popover origin enter (`0.16s`) and exit (`0.11s`) — both ease-out so exits respond immediately.
    public static let popoverEnter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    public static let popoverExit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.11)

    /// Rare/first-time onboarding step slide (`0.28s`, strong ease-out, fully interruptible).
    public static let onboardingStepSlide = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)

    /// Rare/first-time delight spring for onboarding hero layered icons & completion seal.
    public static let onboardingDelightSpring = Animation.spring(duration: 0.48, bounce: 0.16)

    /// Radial shockwave ring expansion on onboarding completion.
    public static let onboardingShockwave = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.68)

    /// Reduced-motion clean cross-fade (`0.15s`).
    public static let reducedMotionFade = Animation.easeOut(duration: 0.15)

    // MARK: - Accessibility & Transition Helpers

    public static func accessible(_ animation: Animation, reduced: Bool) -> Animation {
        reduced ? reducedMotionFade : animation
    }

    /// Asymmetric enter/exit animation (exits shorter than entrances,
    /// reduced motion collapses both to a clean 150ms fade).
    public static func enterExit(
        _ isVisible: Bool,
        enter: Animation = enterSm,
        exit: Animation = exitSm,
        reduced: Bool
    ) -> Animation {
        accessible(isVisible ? enter : exit, reduced: reduced)
    }

    /// Symmetric origin-anchored scale+opacity transition (`0.96 -> 1.0`, never `scale(0)`),
    /// degrading to pure opacity under Reduce Motion.
    public static func originTransition(
        anchor: UnitPoint = .top,
        scale: CGFloat = 0.96,
        reduced: Bool
    ) -> AnyTransition {
        guard !reduced else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: scale, anchor: anchor)),
            removal: .opacity.combined(with: .scale(scale: scale, anchor: anchor))
        )
    }

    /// Gentle vertical reveal (`offsetY -> 0` + `opacity`) for arriving content & stepped AI rows,
    /// degrading to pure opacity under Reduce Motion.
    public static func revealTransition(
        offsetY: CGFloat = 8,
        reduced: Bool
    ) -> AnyTransition {
        guard !reduced else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: offsetY)),
            removal: .opacity
        )
    }

    // MARK: - Drag-to-Reorder Ripple

    /// Neighbor displacement away from the insertion gap: `A * pow(0.7, n)` (`A = 8pt` cards / `6pt` rows).
    public static func rippleOffset(distance: Int, amplitude: CGFloat = 8) -> CGFloat {
        guard distance >= 0 else { return 0 }
        return amplitude * pow(0.7, CGFloat(distance))
    }

    /// Stagger delay propagating outward from the insertion gap: `24ms * n`.
    public static func rippleDelay(distance: Int) -> Double {
        guard distance > 0 else { return 0 }
        return 0.024 * Double(min(distance, 8))
    }
}

// MARK: - Popover Origin Modifier

public struct PopoverOriginScaleModifier: ViewModifier {
    let isPresented: Bool
    let anchor: UnitPoint
    let reducedMotion: Bool

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isPresented ? 1.0 : (reducedMotion ? 1.0 : 0.96), anchor: anchor)
            .opacity(isPresented ? 1.0 : 0.0)
            .animation(
                reducedMotion
                    ? CharkleMotion.reducedMotionFade
                    : (isPresented ? CharkleMotion.popoverEnter : CharkleMotion.popoverExit),
                value: isPresented
            )
    }
}

public extension View {
    /// Applies origin-anchored popover scaling (`0.96 -> 1.0`, opacity `0 -> 1`, `0.16s` enter / `0.11s` exit)
    /// aligned strictly to the trigger edge anchor.
    func popoverOriginScale(
        isPresented: Bool,
        anchor: UnitPoint = .top,
        reducedMotion: Bool
    ) -> some View {
        modifier(PopoverOriginScaleModifier(isPresented: isPresented, anchor: anchor, reducedMotion: reducedMotion))
    }
}

// MARK: - Tactile Press Button Style (Scale 0.97 on Pointer Down, Never Mutating Layout)

public struct CharkleTactileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Skeuomorphic Tactile Keycap Button Style

public enum CharkleSkeuoVariant: Sendable {
    case primary
    case secondary
}

/// Calm, top-lit 5-layer tactile button (face gradient, 1pt outer edge,
/// inner top highlight, inner bottom shade, dual-layer contact + lift shadow, 1pt press travel).
public struct CharkleSkeuoButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private let variant: CharkleSkeuoVariant

    public init(_ variant: CharkleSkeuoVariant = .primary) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        SkeuoButtonBody(
            configuration: configuration,
            variant: variant,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion,
            isEnabled: isEnabled
        )
    }

    private struct SkeuoButtonBody: View {
        let configuration: Configuration
        let variant: CharkleSkeuoVariant
        let colorScheme: ColorScheme
        let reduceMotion: Bool
        let isEnabled: Bool

        @State private var isHovered: Bool = false

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

            let topColor: Color
            let bottomColor: Color
            let borderColor: Color
            let topHighlight: Color
            let bottomShade: Color
            let labelColor: Color
            let contactShadow: Color
            let liftShadow: Color

            switch variant {
            case .primary:
                if colorScheme == .dark {
                    topColor = isHovered ? Color(charkleHex: "#4D5870") : Color(charkleHex: "#414B60")
                    bottomColor = isHovered ? Color(charkleHex: "#313A4D") : Color(charkleHex: "#283144")
                    borderColor = Color(charkleHex: "#151923")
                    topHighlight = Color.white.opacity(0.22)
                    bottomShade = Color.black.opacity(0.32)
                    labelColor = .white
                    contactShadow = Color.black.opacity(0.36)
                    liftShadow = Color.black.opacity(0.45)
                } else {
                    topColor = isHovered ? Color(charkleHex: "#4A5366") : Color(charkleHex: "#404859")
                    bottomColor = isHovered ? Color(charkleHex: "#2F394D") : Color(charkleHex: "#273042")
                    borderColor = Color(charkleHex: "#12161F")
                    topHighlight = Color.white.opacity(0.18)
                    bottomShade = Color.black.opacity(0.24)
                    labelColor = .white
                    contactShadow = Color.black.opacity(0.18)
                    liftShadow = Color(charkleHex: "#12161F").opacity(0.28)
                }
            case .secondary:
                if colorScheme == .dark {
                    topColor = isHovered ? Color(charkleHex: "#2E3139") : Color(charkleHex: "#272A31")
                    bottomColor = isHovered ? Color(charkleHex: "#23262C") : Color(charkleHex: "#1F2127")
                    borderColor = Color.white.opacity(0.14)
                    topHighlight = Color.white.opacity(0.12)
                    bottomShade = Color.black.opacity(0.28)
                    labelColor = .primary
                    contactShadow = Color.black.opacity(0.26)
                    liftShadow = Color.black.opacity(0.30)
                } else {
                    topColor = Color.white
                    bottomColor = isHovered ? Color(charkleHex: "#F7F8FA") : Color(charkleHex: "#F1F3F6")
                    borderColor = Color(charkleHex: "#0F172A").opacity(0.14)
                    topHighlight = Color.white.opacity(0.92)
                    bottomShade = Color.black.opacity(0.06)
                    labelColor = Color(charkleHex: "#1F2633")
                    contactShadow = Color(charkleHex: "#0F172A").opacity(0.06)
                    liftShadow = Color(charkleHex: "#0F172A").opacity(0.09)
                }
            }

            let faceGradient = LinearGradient(
                colors: pressed ? [bottomColor, topColor] : [topColor, bottomColor],
                startPoint: .top,
                endPoint: .bottom
            )

            return configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(labelColor)
                .shadow(color: variant == .primary ? Color.black.opacity(0.26) : .clear, radius: 0, y: -1)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(faceGradient, in: shape)
                .overlay {
                    // Inner top highlight / pressed inner top shadow + bottom shade (strictly following inner radius)
                    shape
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: pressed ? Color.black.opacity(variant == .primary ? 0.34 : 0.14) : topHighlight, location: 0.0),
                                    .init(color: .clear, location: 0.28),
                                    .init(color: .clear, location: 0.78),
                                    .init(color: pressed ? .clear : bottomShade, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                        .padding(0.75)
                }
                .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                .shadow(color: pressed ? contactShadow : liftShadow, radius: pressed ? 1 : (isHovered ? 10 : 7), y: pressed ? 1 : (isHovered ? 5 : 3))
                .shadow(color: contactShadow, radius: 1.5, y: 1)
                .offset(y: pressed && !reduceMotion ? 1 : 0)
                .opacity(isEnabled ? 1.0 : 0.45)
                .contentShape(shape)
                .onHover { hovering in
                    withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                        isHovered = hovering
                    }
                }
                .animation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion), value: pressed)
        }
    }
}

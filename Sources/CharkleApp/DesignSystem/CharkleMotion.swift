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

    /// Critically-damped gliding spring for single-pill continuous nearest-row hover transitions.
    public static let hoverGlide = Animation.spring(duration: 0.20, bounce: 0.0)

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

// MARK: - Legacy Button Style Forwarding Wrapper (Converged onto CharkleButtonStyle)

public nonisolated enum CharkleSkeuoVariant: Sendable {
    case primary
    case secondary
}

/// Thin backwards-compatible forwarding wrapper to `CharkleButtonStyle`.
/// Retires the multi-layer keycap bevel chrome while keeping all existing call sites compiling cleanly
/// onto the unified macOS native button family (`.accent` / `.standard`, `.md` 32pt height).
public struct CharkleSkeuoButtonStyle: ButtonStyle {
    private let variant: CharkleSkeuoVariant

    public init(_ variant: CharkleSkeuoVariant = .primary) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        let mappedVariant: CharkleButtonVariant = switch variant {
        case .primary: .accent
        case .secondary: .standard
        }
        CharkleButtonStyle(mappedVariant, size: .md)
            .makeBody(configuration: configuration)
    }
}

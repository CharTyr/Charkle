import SwiftUI

/// Exact Kubai Design Tips (011 Easing Curves, 005 Drag Ripple, 015 UI Continuity, Note: Popover Origin)
/// motion token registry for Charkle.
///
/// Every transition in Charkle uses one of these role-mapped curves rather than default `.easeInOut`
/// or `.linear` for spatial movement.
public enum CharkleMotion {
    // MARK: - Role-Mapped Timing Curves (Kubai Tip 011)

    /// `--ease-out` (0, 0, 0.58, 1) — Small UI entering (toasts, tooltips, menus, popovers).
    public static let enterSm = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.18)

    /// `--ease-out` (0, 0, 0.58, 1) — Medium UI entering (inspector panels, dialogs, command palette).
    public static let enterMd = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.26)

    /// `--ease-out` (0, 0, 0.58, 1) — Large surfaces entering (sheets, moodboard studio transitions).
    public static let enterLg = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.36)

    /// `--ease-out-strong` (0.22, 1, 0.36, 1) — Crisp active pills, toggles, selected filter chips, stepped reveals.
    public static let settleStrong = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)

    /// `--ease-in` (0.42, 0, 1, 1) — Small UI leaving (shorter than enter!).
    public static let exitSm = Animation.timingCurve(0.42, 0, 1, 1, duration: 0.14)

    /// `--ease-in` (0.42, 0, 1, 1) — Medium UI leaving (always shorter than enter!).
    public static let exitMd = Animation.timingCurve(0.42, 0, 1, 1, duration: 0.19)

    /// `--ease-in-out` (0.42, 0, 0.58, 1) — Elements already on screen moving/resizing (segmented indicator, reflow).
    public static let moveOnScreen = Animation.timingCurve(0.42, 0, 0.58, 1, duration: 0.26)

    /// `--ease-overshoot` (0.34, 1.56, 0.64, 1) — Tiny ≤64px confirmations ONLY (checkbox tick, rating star, badge pop).
    public static let microOvershoot = Animation.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.28)

    /// Momentum spring for drag release, Notch Shelf morphing, Quick Look zoom-to-card, Auto↔Freeform reflow.
    public static let gestureSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// Critically damped UI spring for responsive state morphs without bounce.
    public static let uiSpring = Animation.spring(response: 0.32, dampingFraction: 1.0)

    /// Fast micro-tactile hover & pointer-down feedback (never animate layout on hover!).
    public static let hoverPress = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.12)

    /// Popover origin enter (`0.16s`) and exit (`0.11s`) per Kubai Popover Origin note.
    public static let popoverEnter = Animation.timingCurve(0, 0, 0.58, 1, duration: 0.16)
    public static let popoverExit = Animation.timingCurve(0.42, 0, 1, 1, duration: 0.11)

    /// Reduced-motion clean cross-fade (`0.15s`).
    public static let reducedMotionFade = Animation.easeOut(duration: 0.15)

    // MARK: - Accessibility Helper

    public static func accessible(_ animation: Animation, reduced: Bool) -> Animation {
        reduced ? reducedMotionFade : animation
    }

    // MARK: - Kubai Tip 005 Drag-to-Reorder Ripple

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

// MARK: - Popover Origin Modifier (Kubai Popover Origin Note)

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
    /// Applies Kubai Popover Origin scaling (`0.96 -> 1.0`, opacity `0 -> 1`, `0.16s` enter / `0.11s` exit)
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

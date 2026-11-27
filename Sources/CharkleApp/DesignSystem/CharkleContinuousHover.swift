import CharkleCanvas
import Observation
import SwiftUI

/// Isolated controller for single-element continuous nearest-row hover.
///
/// Row frames are stored in `@ObservationIgnored` storage so layout/scroll geometry updates
/// cause zero SwiftUI body invalidations. Only `activeTarget` is observed — exclusively by
/// `CharkleContinuousHoverPillLayer` — so moving the cursor across dozens or hundreds of rows
/// never re-renders the parent sidebar or any individual row.
@MainActor
@Observable
public final class CharkleContinuousHoverController {
    @ObservationIgnored private var framesByID: [String: CGRect] = [:]
    @ObservationIgnored private var cachedTargets: [ContinuousHoverTarget] = []
    @ObservationIgnored private var isTargetCacheDirty: Bool = false
    @ObservationIgnored private var lastPointerY: CGFloat? = nil
    @ObservationIgnored private var maxVerticalReach: CGFloat? = nil

    public private(set) var activeTarget: ContinuousHoverTarget? = nil

    public init(maxVerticalReach: CGFloat? = 44) {
        self.maxVerticalReach = maxVerticalReach
    }

    public func updateTarget(id: String, frame: CGRect) {
        guard frame.width > 0, frame.height > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite else {
            return
        }
        if framesByID[id] == frame { return }
        framesByID[id] = frame
        isTargetCacheDirty = true

        if let pointerY = lastPointerY {
            resolveAndPublish(pointerY: pointerY)
        } else if let current = activeTarget, current.id == id {
            activeTarget = ContinuousHoverTarget(id: id, frame: frame)
        }
    }

    public func removeTarget(id: String) {
        guard framesByID.removeValue(forKey: id) != nil else { return }
        isTargetCacheDirty = true
        if let pointerY = lastPointerY {
            resolveAndPublish(pointerY: pointerY)
        } else if activeTarget?.id == id {
            activeTarget = nil
        }
    }

    public func handlePointerMove(y: CGFloat) {
        lastPointerY = y
        resolveAndPublish(pointerY: y)
    }

    public func clear() {
        lastPointerY = nil
        if activeTarget != nil {
            activeTarget = nil
        }
    }

    private func resolveAndPublish(pointerY: CGFloat) {
        if isTargetCacheDirty {
            cachedTargets = framesByID.map { ContinuousHoverTarget(id: $0.key, frame: $0.value) }
            isTargetCacheDirty = false
        }
        let next = ContinuousHoverResolver.nearestTarget(
            to: pointerY,
            in: cachedTargets,
            maxVerticalReach: maxVerticalReach
        )
        if activeTarget != next {
            activeTarget = next
        }
    }
}

/// Single GPU-positioned highlight pill rendered behind a list/sidebar container.
///
/// - First entry snaps instantaneously to the entered row and fades in (never flies in from `(0, 0)`).
/// - Subsequent moves glide smoothly via one `offset` transform with critically-damped spring physics.
/// - Pointer exit or modal overlay suspension fades out cleanly in place.
private struct CharkleContinuousHoverPillLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let controller: CharkleContinuousHoverController
    let cornerRadius: CGFloat
    let isSuppressed: Bool

    @State private var displayedFrame: CGRect = .zero
    @State private var isVisible: Bool = false

    private var pillFill: Color {
        if colorScheme == .dark {
            return Color.white.opacity(reduceTransparency ? 0.11 : 0.075)
        } else {
            return Color.black.opacity(reduceTransparency ? 0.075 : 0.05)
        }
    }

    var body: some View {
        let effectiveTarget = isSuppressed ? nil : controller.activeTarget

        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(pillFill)
            .frame(width: max(0, displayedFrame.width), height: max(0, displayedFrame.height))
            .offset(x: displayedFrame.minX, y: displayedFrame.minY)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: effectiveTarget) { _, newTarget in
                applyTargetChange(newTarget)
            }
            .onAppear {
                if let initial = effectiveTarget {
                    applyTargetChange(initial)
                }
            }
    }

    private func applyTargetChange(_ newTarget: ContinuousHoverTarget?) {
        guard let target = newTarget else {
            guard isVisible else { return }
            withAnimation(CharkleMotion.accessible(CharkleMotion.exitSm, reduced: reduceMotion)) {
                isVisible = false
            }
            return
        }

        if !isVisible {
            // Snap directly behind the entered target before fading in so the pill never flies from (0, 0).
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                displayedFrame = target.frame
            }
            withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                isVisible = true
            }
        } else {
            if reduceMotion {
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) {
                    displayedFrame = target.frame
                }
            } else {
                withAnimation(CharkleMotion.hoverGlide) {
                    displayedFrame = target.frame
                }
            }
        }
    }
}

private struct CharkleContinuousHoverContainerModifier: ViewModifier {
    @Environment(\.charkleOverlayInteractionSuspended) private var isOverlayInteractionSuspended

    let scope: String
    let controller: CharkleContinuousHoverController
    let cornerRadius: CGFloat
    let isSuspended: Bool

    private var effectivelySuspended: Bool {
        isSuspended || isOverlayInteractionSuspended
    }

    func body(content: Content) -> some View {
        content
            .background(alignment: .topLeading) {
                CharkleContinuousHoverPillLayer(
                    controller: controller,
                    cornerRadius: cornerRadius,
                    isSuppressed: effectivelySuspended
                )
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                if effectivelySuspended {
                    controller.clear()
                    return
                }
                switch phase {
                case .active(let location):
                    controller.handlePointerMove(y: location.y)
                case .ended:
                    controller.clear()
                }
            }
            .coordinateSpace(name: scope)
            .onChange(of: effectivelySuspended) { _, suspended in
                if suspended {
                    controller.clear()
                }
            }
            .onDisappear {
                controller.clear()
            }
    }
}

private struct CharkleContinuousHoverTargetModifier: ViewModifier {
    let id: String
    let scope: String
    let controller: CharkleContinuousHoverController

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(scope))
            } action: { newFrame in
                controller.updateTarget(id: id, frame: newFrame)
            }
            .onDisappear {
                controller.removeTarget(id: id)
            }
    }
}

public extension View {
    /// Attaches a single shared gliding highlight pill and zero-dead-zone nearest-row hover tracking
    /// to a vertical list or sidebar container.
    func charkleContinuousHoverContainer(
        scope: String,
        controller: CharkleContinuousHoverController,
        cornerRadius: CGFloat = CharkleTheme.Radius.chip,
        isSuspended: Bool = false
    ) -> some View {
        modifier(
            CharkleContinuousHoverContainerModifier(
                scope: scope,
                controller: controller,
                cornerRadius: cornerRadius,
                isSuspended: isSuspended
            )
        )
    }

    /// Registers this row's frame with the enclosing `charkleContinuousHoverContainer`.
    func charkleContinuousHoverTarget(
        id: String,
        in scope: String,
        controller: CharkleContinuousHoverController
    ) -> some View {
        modifier(
            CharkleContinuousHoverTargetModifier(
                id: id,
                scope: scope,
                controller: controller
            )
        )
    }
}

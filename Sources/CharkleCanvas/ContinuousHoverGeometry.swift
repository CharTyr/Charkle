import CoreGraphics
import Foundation

/// Geometry snapshot for a single selectable row participating in continuous nearest-item hover.
public nonisolated struct ContinuousHoverTarget: Equatable, Hashable, Sendable {
    public let id: String
    public let frame: CGRect

    public init(id: String, frame: CGRect) {
        self.id = id
        self.frame = frame
    }

    public var midY: CGFloat {
        frame.midY
    }
}

/// Pure nearest-item targeting math for continuous gliding list/sidebar hover.
///
/// Single rule with zero inter-row dead zones: on every pointer move, a single linear pass
/// picks the row whose vertical center (`midY`) is closest to `pointerY`, bridging gaps,
/// drag-insertion slots, section dividers, and container edge padding seamlessly.
public nonisolated enum ContinuousHoverResolver {
    /// Resolves the nearest target to `pointerY` in one linear pass.
    ///
    /// - Parameters:
    ///   - pointerY: Pointer Y coordinate in the shared container coordinate space.
    ///   - targets: Registered row frames in the same coordinate space.
    ///   - maxVerticalReach: Optional maximum distance beyond the nearest target's top/bottom
    ///     edge before releasing hover (prevents lighting up a distant row when hovering far
    ///     below a short list in blank scroll area, while bridging inter-row gaps and edge padding).
    /// - Returns: The winning `ContinuousHoverTarget`, or `nil` when empty, non-finite, or out of reach.
    public static func nearestTarget(
        to pointerY: CGFloat,
        in targets: [ContinuousHoverTarget],
        maxVerticalReach: CGFloat? = nil
    ) -> ContinuousHoverTarget? {
        guard !targets.isEmpty, pointerY.isFinite else { return nil }

        var best: ContinuousHoverTarget? = nil
        var bestCenterDistance = CGFloat.greatestFiniteMagnitude

        for target in targets {
            let rect = target.frame
            guard rect.width > 0, rect.height > 0,
                  rect.minY.isFinite, rect.maxY.isFinite else {
                continue
            }
            let distance = abs(pointerY - rect.midY)
            if distance < bestCenterDistance {
                bestCenterDistance = distance
                best = target
            } else if distance == bestCenterDistance, let current = best, target.frame.minY < current.frame.minY {
                best = target
            }
        }

        guard let winner = best else { return nil }

        if let maxVerticalReach, maxVerticalReach.isFinite {
            let edgeDistance: CGFloat
            if pointerY < winner.frame.minY {
                edgeDistance = winner.frame.minY - pointerY
            } else if pointerY > winner.frame.maxY {
                edgeDistance = pointerY - winner.frame.maxY
            } else {
                edgeDistance = 0
            }
            if edgeDistance > maxVerticalReach {
                return nil
            }
        }

        return winner
    }
}

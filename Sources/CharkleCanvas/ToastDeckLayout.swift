import CoreGraphics
import Foundation

/// Visual presentation parameters for a single toast card inside the bottom-right 2.5D receding deck.
public struct CharkleToastDeckCardStyle: Equatable, Sendable {
    public let depth: Int
    public let isVisible: Bool
    public let yOffset: CGFloat
    public let scale: CGFloat
    public let opacity: Double
    public let blurRadius: CGFloat
    public let tiltDegrees: Double
    public let zIndex: Double
    public let allowsHitTesting: Bool

    public init(
        depth: Int,
        isVisible: Bool,
        yOffset: CGFloat,
        scale: CGFloat,
        opacity: Double,
        blurRadius: CGFloat,
        tiltDegrees: Double,
        zIndex: Double,
        allowsHitTesting: Bool
    ) {
        self.depth = depth
        self.isVisible = isVisible
        self.yOffset = yOffset
        self.scale = scale
        self.opacity = opacity
        self.blurRadius = blurRadius
        self.tiltDegrees = tiltDegrees
        self.zIndex = zIndex
        self.allowsHitTesting = allowsHitTesting
    }
}

/// Pure, deterministic geometry solver for Charkle's bottom-right bottom-up 2.5D toast stack:
/// - Keeps collapsed deck height tightly bounded regardless of how many toasts fire in rapid succession.
/// - Recedes older toasts backward in 2.5D perspective (`depth = 0` frontmost -> `1, 2, 3` peeking -> `4+` hidden).
/// - Fans out cleanly upward on hover up to `maxVisibleExpanded` items so the stack never fills the screen.
public enum CharkleToastDeckLayout {
    public static let maxVisibleCollapsed: Int = 4
    public static let maxVisibleExpanded: Int = 5
    public static let maxRenderedCount: Int = 6
    public static let expandedSpacing: CGFloat = 8
    public static let defaultRowHeight: CGFloat = 38

    public static func collapsedCardStyle(
        depth: Int,
        reduceMotion: Bool
    ) -> CharkleToastDeckCardStyle {
        let d = max(0, depth)
        switch d {
        case 0:
            return CharkleToastDeckCardStyle(
                depth: 0,
                isVisible: true,
                yOffset: 0,
                scale: 1.0,
                opacity: 1.0,
                blurRadius: 0,
                tiltDegrees: 0,
                zIndex: 1000,
                allowsHitTesting: true
            )
        case 1:
            return CharkleToastDeckCardStyle(
                depth: 1,
                isVisible: true,
                yOffset: -10,
                scale: 0.94,
                opacity: 0.84,
                blurRadius: reduceMotion ? 0 : 0.35,
                tiltDegrees: reduceMotion ? 0 : 2.2,
                zIndex: 999,
                allowsHitTesting: false
            )
        case 2:
            return CharkleToastDeckCardStyle(
                depth: 2,
                isVisible: true,
                yOffset: -19,
                scale: 0.88,
                opacity: 0.58,
                blurRadius: reduceMotion ? 0 : 0.85,
                tiltDegrees: reduceMotion ? 0 : 4.2,
                zIndex: 998,
                allowsHitTesting: false
            )
        case 3:
            return CharkleToastDeckCardStyle(
                depth: 3,
                isVisible: true,
                yOffset: -27,
                scale: 0.82,
                opacity: 0.28,
                blurRadius: reduceMotion ? 0 : 1.4,
                tiltDegrees: reduceMotion ? 0 : 6.0,
                zIndex: 997,
                allowsHitTesting: false
            )
        default:
            return CharkleToastDeckCardStyle(
                depth: d,
                isVisible: false,
                yOffset: -33,
                scale: 0.76,
                opacity: 0.0,
                blurRadius: reduceMotion ? 0 : 2.0,
                tiltDegrees: reduceMotion ? 0 : 7.5,
                zIndex: Double(max(0, 1000 - d)),
                allowsHitTesting: false
            )
        }
    }

    public static func expandedCardStyle(
        depth: Int,
        heightsFromFront: [CGFloat],
        reduceMotion: Bool
    ) -> CharkleToastDeckCardStyle {
        let d = max(0, depth)
        let cappedIndex = min(d, maxVisibleExpanded)
        var cumulativeY: CGFloat = 0
        for idx in 0..<cappedIndex {
            let h = idx < heightsFromFront.count ? max(28, heightsFromFront[idx]) : defaultRowHeight
            cumulativeY += h + expandedSpacing
        }

        if d < maxVisibleExpanded {
            return CharkleToastDeckCardStyle(
                depth: d,
                isVisible: true,
                yOffset: -cumulativeY,
                scale: 1.0,
                opacity: 1.0,
                blurRadius: 0,
                tiltDegrees: 0,
                zIndex: Double(1000 - d),
                allowsHitTesting: true
            )
        }

        return CharkleToastDeckCardStyle(
            depth: d,
            isVisible: false,
            yOffset: -(cumulativeY - expandedSpacing + 6),
            scale: 0.92,
            opacity: 0.0,
            blurRadius: reduceMotion ? 0 : 1.0,
            tiltDegrees: 0,
            zIndex: Double(max(0, 1000 - d)),
            allowsHitTesting: false
        )
    }

    public static func collapsedDeckHeight(frontHeight: CGFloat, toastCount: Int) -> CGFloat {
        guard toastCount > 0 else { return 0 }
        let safeFront = max(28, frontHeight)
        let deepestVisible = min(toastCount - 1, maxVisibleCollapsed - 1)
        let peek = abs(collapsedCardStyle(depth: deepestVisible, reduceMotion: true).yOffset)
        return safeFront + peek
    }

    public static func expandedContentHeight(heightsFromFront: [CGFloat]) -> CGFloat {
        let visibleCount = min(heightsFromFront.count, maxVisibleExpanded)
        guard visibleCount > 0 else { return 0 }
        var total: CGFloat = 0
        for idx in 0..<visibleCount {
            total += max(28, heightsFromFront[idx])
            if idx + 1 < visibleCount {
                total += expandedSpacing
            }
        }
        return total
    }

    public static func hiddenOverflowCount(totalCount: Int, isExpanded: Bool) -> Int {
        let visibleCap = isExpanded ? maxVisibleExpanded : maxVisibleCollapsed
        return max(0, totalCount - visibleCap)
    }
}

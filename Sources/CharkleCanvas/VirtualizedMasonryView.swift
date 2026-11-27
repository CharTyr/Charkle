import AppKit
import CharkleCore
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Deterministic O(N) Masonry Layout Engine

public nonisolated struct MasonryItemFrame: Sendable, Equatable {
    public let id: UUID
    public let index: Int
    public let rect: CGRect
}

public nonisolated struct MasonryLayoutSnapshot: Sendable, Equatable {
    public let items: [MasonryItemFrame]
    public let totalHeight: CGFloat
    public let columnCount: Int
    public let columnWidth: CGFloat
    /// Monotonically non-decreasing running max of `items[0...i].rect.maxY` for O(log N) culling.
    private let prefixMaxY: [CGFloat]

    public init(items: [MasonryItemFrame], totalHeight: CGFloat, columnCount: Int, columnWidth: CGFloat) {
        self.items = items
        self.totalHeight = totalHeight
        self.columnCount = columnCount
        self.columnWidth = columnWidth
        var prefix: [CGFloat] = []
        prefix.reserveCapacity(items.count)
        var runningMax: CGFloat = 0
        for item in items {
            if item.rect.maxY > runningMax {
                runningMax = item.rect.maxY
            }
            prefix.append(runningMax)
        }
        self.prefixMaxY = prefix
    }

    private init(
        items: [MasonryItemFrame],
        totalHeight: CGFloat,
        columnCount: Int,
        columnWidth: CGFloat,
        prefixMaxY: [CGFloat]
    ) {
        self.items = items
        self.totalHeight = totalHeight
        self.columnCount = columnCount
        self.columnWidth = columnWidth
        self.prefixMaxY = prefixMaxY
    }

    public static let empty = MasonryLayoutSnapshot(items: [], totalHeight: 0, columnCount: 1, columnWidth: 240)

    /// O(1) totalHeight update when only `bottomInset` changes (e.g., multi-select action bar toggle),
    /// sharing `items` and `prefixMaxY` via CoW with zero re-layout.
    internal func withAdjustedBottomInset(oldBottomInset: CGFloat, newBottomInset: CGFloat) -> MasonryLayoutSnapshot {
        MasonryLayoutSnapshot(
            items: items,
            totalHeight: max(360, totalHeight - oldBottomInset + newBottomInset),
            columnCount: columnCount,
            columnWidth: columnWidth,
            prefixMaxY: prefixMaxY
        )
    }

    /// Zero-allocation O(log N + K) visitor over all items intersecting `[minY, maxY]`.
    @inline(__always)
    internal func forEachVisibleItem(minY: CGFloat, maxY: CGFloat, _ body: (MasonryItemFrame) -> Void) {
        guard !items.isEmpty, maxY >= minY else { return }

        var lo = 0
        var hi = items.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if prefixMaxY[mid] < minY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo < items.count else { return }

        for idx in lo..<items.count {
            let item = items[idx]
            if item.rect.minY > maxY {
                break
            }
            if item.rect.maxY >= minY {
                body(item)
            }
        }
    }

    /// Returns only the items intersecting `[minY, maxY]` in O(log N + K) time.
    /// Relies on two invariants guaranteed by `MasonryLayoutEngine.compute`:
    /// 1) `prefixMaxY` is non-decreasing (binary search finds the first candidate index), and
    /// 2) `items[i].rect.minY` is non-decreasing (every item is placed in the shortest column),
    ///    so scanning stops immediately once `item.rect.minY > maxY`.
    public func visibleItems(minY: CGFloat, maxY: CGFloat) -> [MasonryItemFrame] {
        guard !items.isEmpty, maxY >= minY else { return [] }

        var lo = 0
        var hi = items.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if prefixMaxY[mid] < minY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo < items.count else { return [] }

        var result: [MasonryItemFrame] = []
        result.reserveCapacity(64)
        for idx in lo..<items.count {
            let item = items[idx]
            if item.rect.minY > maxY {
                break
            }
            if item.rect.maxY >= minY {
                result.append(item)
            }
        }
        return result
    }

    /// Returns IDs of all items intersecting `rect` in O(log N + K) time.
    public func intersectingIDs(in rect: CGRect) -> [UUID] {
        var ids: [UUID] = []
        ids.reserveCapacity(32)
        forEachVisibleItem(minY: rect.minY, maxY: rect.maxY) { item in
            if item.rect.intersects(rect) {
                ids.append(item.id)
            }
        }
        return ids
    }
}

public nonisolated enum MasonryLayoutEngine {
    public static let minColumnWidth: CGFloat = 130
    public static let maxColumnWidth: CGFloat = 420
    public static let minVerticalColumns: Int = 2
    public static let maxVerticalColumns: Int = 10

    /// Logarithmic ~18% density stops for Horizontal Justified mode so pinch, slider, and +/- buttons
    /// step cleanly without thrashing row line-breaks on every 1pt drag tick.
    public static let justifiedZoomStops: [CGFloat] = [130, 154, 182, 214, 252, 298, 354, 420]

    public static func verticalColumnCount(
        containerWidth: CGFloat,
        targetColumnWidth: CGFloat,
        spacing: CGFloat = 12,
        horizontalPadding: CGFloat = 20
    ) -> Int {
        let usableWidth = max(240, containerWidth - horizontalPadding * 2)
        let rawCols = Int(((usableWidth + spacing) / max(120, targetColumnWidth + spacing)).rounded(.down))
        return max(minVerticalColumns, min(maxVerticalColumns, rawCols))
    }

    public static func verticalColumnWidth(
        containerWidth: CGFloat,
        columnCount: Int,
        spacing: CGFloat = 12,
        horizontalPadding: CGFloat = 20
    ) -> CGFloat {
        let usableWidth = max(240, containerWidth - horizontalPadding * 2)
        let cols = max(minVerticalColumns, min(maxVerticalColumns, columnCount))
        return (usableWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)
    }

    public static func minReachableVerticalColumns(
        containerWidth: CGFloat,
        spacing: CGFloat = 12,
        horizontalPadding: CGFloat = 20
    ) -> Int {
        verticalColumnCount(
            containerWidth: containerWidth,
            targetColumnWidth: maxColumnWidth,
            spacing: spacing,
            horizontalPadding: horizontalPadding
        )
    }

    public static func maxReachableVerticalColumns(
        containerWidth: CGFloat,
        spacing: CGFloat = 12,
        horizontalPadding: CGFloat = 20
    ) -> Int {
        verticalColumnCount(
            containerWidth: containerWidth,
            targetColumnWidth: minColumnWidth,
            spacing: spacing,
            horizontalPadding: horizontalPadding
        )
    }

    /// Returns a stable interior `targetColumnWidth` guaranteed to resolve to `columnCount` columns
    /// with maximum hysteresis margin on both sides.
    public static func canonicalTargetWidth(
        forVerticalColumns columnCount: Int,
        containerWidth: CGFloat,
        spacing: CGFloat = 12,
        horizontalPadding: CGFloat = 20
    ) -> CGFloat {
        let minCols = minReachableVerticalColumns(containerWidth: containerWidth, spacing: spacing, horizontalPadding: horizontalPadding)
        let maxCols = maxReachableVerticalColumns(containerWidth: containerWidth, spacing: spacing, horizontalPadding: horizontalPadding)
        let cols = max(minCols, min(maxCols, columnCount))
        let upper = verticalColumnWidth(
            containerWidth: containerWidth,
            columnCount: cols,
            spacing: spacing,
            horizontalPadding: horizontalPadding
        )
        let lower = verticalColumnWidth(
            containerWidth: containerWidth,
            columnCount: cols + 1,
            spacing: spacing,
            horizontalPadding: horizontalPadding
        )
        let clampedUpper = min(maxColumnWidth, upper)
        let clampedLower = max(minColumnWidth, lower)
        let ideal: CGFloat
        if cols <= minCols {
            ideal = min(maxColumnWidth, max((clampedUpper + clampedLower) * 0.5, clampedUpper * 0.94))
        } else if cols >= maxCols {
            ideal = max(minColumnWidth, min((clampedUpper + clampedLower) * 0.5, clampedLower * 1.06))
        } else {
            ideal = (clampedUpper + clampedLower) * 0.5
        }
        return max(minColumnWidth, min(maxColumnWidth, ideal))
    }

    /// Snaps a raw slider/zoom width to the closest clean density stop for Horizontal Justified mode.
    public static func snappedJustifiedTargetWidth(_ rawWidth: CGFloat) -> CGFloat {
        let clamped = max(minColumnWidth, min(maxColumnWidth, rawWidth))
        var best = justifiedZoomStops[0]
        var bestDist = abs(clamped - best)
        for stop in justifiedZoomStops.dropFirst() {
            let dist = abs(clamped - stop)
            if dist < bestDist {
                bestDist = dist
                best = stop
            }
        }
        return best
    }

    /// Steps density cleanly by exactly 1 column (Vertical Masonry) or 1 logarithmic stop (Horizontal Justified).
    /// `direction > 0` zooms IN (larger cards, fewer columns); `direction < 0` zooms OUT (smaller cards, more columns).
    public static func steppedColumnWidth(
        currentWidth: CGFloat,
        direction: Int,
        layoutMode: GalleryLayoutMode,
        containerWidth: CGFloat,
        spacing: CGFloat = 12,
        horizontalPadding: CGFloat = 20
    ) -> CGFloat {
        guard direction != 0 else { return max(minColumnWidth, min(maxColumnWidth, currentWidth)) }
        let zoomIn = direction > 0
        switch layoutMode {
        case .verticalMasonry, .galleryFilmstrip, .ringGallery:
            let minCols = minReachableVerticalColumns(containerWidth: containerWidth, spacing: spacing, horizontalPadding: horizontalPadding)
            let maxCols = maxReachableVerticalColumns(containerWidth: containerWidth, spacing: spacing, horizontalPadding: horizontalPadding)
            let currentCols = verticalColumnCount(
                containerWidth: containerWidth,
                targetColumnWidth: currentWidth,
                spacing: spacing,
                horizontalPadding: horizontalPadding
            )
            let targetCols = max(minCols, min(maxCols, currentCols + (zoomIn ? -1 : 1)))
            return canonicalTargetWidth(
                forVerticalColumns: targetCols,
                containerWidth: containerWidth,
                spacing: spacing,
                horizontalPadding: horizontalPadding
            )
        case .horizontalJustified:
            let snapped = snappedJustifiedTargetWidth(currentWidth)
            let idx = justifiedZoomStops.firstIndex(of: snapped) ?? 0
            let nextIdx = max(0, min(justifiedZoomStops.count - 1, idx + (zoomIn ? 1 : -1)))
            return justifiedZoomStops[nextIdx]
        }
    }

    /// Computes the exact post-zoom scroll origin Y that keeps an exact anchor asset's normalized vertical point
    /// `(anchorNormV)` pinned to `anchorScreenY` on screen (accounting for any rebased optical pinch scale).
    /// Row-1 cards at the very top of the library (`oldScrollY <= 2 && oldAnchorRect.minY <= topInset + 4`) stay
    /// cleanly anchored at `scrollY = 0` so they never clip beneath the floating top bar, while Row-2+ cards
    /// scroll automatically to remain stationary under the user's eye even when zooming from the top.
    public static func anchoredScrollY(
        oldScrollY: CGFloat,
        oldAnchorRect: CGRect,
        newAnchorRect: CGRect,
        anchorNormV: CGFloat,
        anchorScreenY: CGFloat,
        newOpticalScale: CGFloat = 1.0,
        opticalAnchorScreenY: CGFloat = 0,
        topInset: CGFloat = 76,
        totalHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maxScrollY = max(0, totalHeight - viewportHeight)
        if oldScrollY <= 2 && oldAnchorRect.minY <= topInset + 4 && newAnchorRect.minY <= topInset + 4 {
            return 0
        }
        let newAnchorPointY = newAnchorRect.minY + anchorNormV * newAnchorRect.height
        let targetRawY = opticalAnchorScreenY + (anchorScreenY - opticalAnchorScreenY) / max(0.1, newOpticalScale)
        return max(0, min(maxScrollY, newAnchorPointY - targetRawY))
    }

    /// Projects a tile's pre-handoff visual screen rect into post-scroll, post-optical document coordinates
    /// so frame 0 of the reflow animation starts at the exact same on-screen pixel (0.0pt jump).
    public static func compensatedFromRect(
        oldScreenRect: CGRect,
        newScrollY: CGFloat,
        newOpticalScale: CGFloat = 1.0,
        newOpticalAnchorScreen: CGPoint = .zero
    ) -> CGRect {
        let invS = 1.0 / max(0.1, newOpticalScale)
        let docMidX = newOpticalAnchorScreen.x + (oldScreenRect.midX - newOpticalAnchorScreen.x) * invS
        let docMidY = (newScrollY + newOpticalAnchorScreen.y) + (oldScreenRect.midY - newOpticalAnchorScreen.y) * invS
        let docW = oldScreenRect.width * invS
        let docH = oldScreenRect.height * invS
        return CGRect(
            x: docMidX - docW * 0.5,
            y: docMidY - docH * 0.5,
            width: docW,
            height: docH
        )
    }

    /// Computes the deterministic post-drawer target viewport width when a side pane
    /// (Sidebar collapse/expand or Inspector show/hide) changes total chrome width.
    /// Pass any active in-flight target width as `currentViewportWidth` so rapid mid-flight
    /// reversals stay mathematically exact without drifting.
    public static func paneTransitionTargetWidth(
        currentViewportWidth: CGFloat,
        previousSideChromeWidth: CGFloat,
        newSideChromeWidth: CGFloat,
        minWidth: CGFloat = 240
    ) -> CGFloat {
        let delta = previousSideChromeWidth - newSideChromeWidth
        return max(minWidth, floor(currentViewportWidth + delta))
    }

    /// Computes post-drawer scroll origin for Sidebar/Inspector pane transitions:
    /// keeps `scrollY = 0` when already at the top of the library (`oldScrollY <= 4`) so Row 1 never
    /// scrolls off-screen, while anchoring the mid-viewport card cleanly when scrolled further down.
    public static func paneTransitionScrollY(
        oldScrollY: CGFloat,
        oldAnchorRect: CGRect,
        newAnchorRect: CGRect,
        anchorNormV: CGFloat,
        anchorScreenY: CGFloat,
        topInset: CGFloat = 76,
        totalHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        if oldScrollY <= 4 {
            return 0
        }
        return anchoredScrollY(
            oldScrollY: oldScrollY,
            oldAnchorRect: oldAnchorRect,
            newAnchorRect: newAnchorRect,
            anchorNormV: anchorNormV,
            anchorScreenY: anchorScreenY,
            topInset: topInset,
            totalHeight: totalHeight,
            viewportHeight: viewportHeight
        )
    }

    /// Computes the clamped vertical scroll origin that centers an asset card vertically within the usable
    /// viewport area beneath `topInset` (and above `bottomInset`), used when revealing an asset from Moodboard or Jump.
    public static func revealScrollY(
        for itemRect: CGRect,
        topInset: CGFloat,
        bottomInset: CGFloat,
        totalHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        let maxScrollY = max(0, totalHeight - viewportHeight)
        guard maxScrollY > 0 else { return 0 }
        let usableHeight = max(80, viewportHeight - topInset - min(bottomInset, viewportHeight * 0.25))
        let targetCenterY = topInset + usableHeight * 0.5
        return max(0, min(maxScrollY, itemRect.midY - targetCenterY))
    }

    public enum NavigationDirection: Sendable {
        case left
        case right
        case up
        case down
    }

    /// 2D spatial keyboard navigation across both Vertical Masonry and Horizontal Justified layouts.
    public static func nextAssetIndex(
        from currentIndex: Int,
        direction: NavigationDirection,
        in snapshot: MasonryLayoutSnapshot
    ) -> Int? {
        let count = snapshot.items.count
        guard count > 0 else { return nil }
        guard currentIndex >= 0, currentIndex < count else { return 0 }

        let current = snapshot.items[currentIndex]
        let curRect = current.rect

        switch direction {
        case .left, .right:
            let goingRight = (direction == .right)
            let searchPadY = max(curRect.height * 1.4, 260)
            var bestIndex: Int?
            var bestScore = CGFloat.greatestFiniteMagnitude
            snapshot.forEachVisibleItem(minY: max(0, curRect.minY - searchPadY), maxY: curRect.maxY + searchPadY) { cand in
                guard cand.index != currentIndex else { return }
                let dx = cand.rect.midX - curRect.midX
                if goingRight ? (dx <= 4) : (dx >= -4) { return }
                let dy = abs(cand.rect.midY - curRect.midY)
                let rowTolerance = max(curRect.height, cand.rect.height) * 0.65
                guard dy <= rowTolerance else { return }
                let score = abs(dx) + dy * 1.5
                if score < bestScore {
                    bestScore = score
                    bestIndex = cand.index
                }
            }
            if let bestIndex { return bestIndex }
            let linear = goingRight ? (currentIndex + 1) : (currentIndex - 1)
            return (linear >= 0 && linear < count) ? linear : currentIndex

        case .up, .down:
            let goingDown = (direction == .down)
            let searchSpanY = max(curRect.height * 4.0, 960)
            let minY = goingDown ? curRect.minY : max(0, curRect.minY - searchSpanY)
            let maxY = goingDown ? (curRect.maxY + searchSpanY) : curRect.maxY
            var bestIndex: Int?
            var bestScore = CGFloat.greatestFiniteMagnitude
            snapshot.forEachVisibleItem(minY: minY, maxY: maxY) { cand in
                guard cand.index != currentIndex else { return }
                let dy = cand.rect.midY - curRect.midY
                let minStep = min(curRect.height, cand.rect.height) * 0.30
                if goingDown ? (dy <= max(6, minStep)) : (dy >= -max(6, minStep)) { return }
                let dx = abs(cand.rect.midX - curRect.midX)
                let score = dx * 2.4 + abs(dy)
                if score < bestScore {
                    bestScore = score
                    bestIndex = cand.index
                }
            }
            return bestIndex ?? currentIndex
        }
    }

    public static func compute(
        assets: [AssetRecord],
        layoutMode: GalleryLayoutMode = .verticalMasonry,
        containerWidth: CGFloat,
        targetColumnWidth: CGFloat,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> MasonryLayoutSnapshot {
        switch layoutMode {
        case .verticalMasonry, .galleryFilmstrip, .ringGallery:
            return computeVertical(
                assets: assets,
                containerWidth: containerWidth,
                targetColumnWidth: targetColumnWidth,
                spacing: spacing,
                horizontalPadding: horizontalPadding,
                topInset: topInset,
                bottomInset: bottomInset
            )
        case .horizontalJustified:
            let targetRowH = max(116, min(360, targetColumnWidth * 0.92))
            return computeJustified(
                assets: assets,
                containerWidth: containerWidth,
                targetRowHeight: targetRowH,
                spacing: spacing,
                horizontalPadding: horizontalPadding,
                topInset: topInset,
                bottomInset: bottomInset
            )
        }
    }

    private static func effectiveAspectRatio(for asset: AssetRecord, clampedRange: ClosedRange<CGFloat>) -> CGFloat {
        let rawRatio: CGFloat = switch asset.mediaKind {
        case .audio: 1.55
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
        case .document: asset.fileName.lowercased().hasSuffix(".swatch") ? 1.0 : 0.84
        case .model3D: asset.pixelWidth > 0 && asset.pixelHeight > 0 ? CGFloat(asset.aspectRatio) : 1.0
        default: CGFloat(asset.aspectRatio)
        }
        return max(clampedRange.lowerBound, min(clampedRange.upperBound, rawRatio))
    }

    private static func computeVertical(
        assets: [AssetRecord],
        containerWidth: CGFloat,
        targetColumnWidth: CGFloat,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> MasonryLayoutSnapshot {
        let usableWidth = max(240, containerWidth - horizontalPadding * 2)
        let cols = verticalColumnCount(
            containerWidth: containerWidth,
            targetColumnWidth: targetColumnWidth,
            spacing: spacing,
            horizontalPadding: horizontalPadding
        )
        let colWidth = (usableWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)

        var colHeights = Array(repeating: topInset, count: cols)
        var frames: [MasonryItemFrame] = []
        frames.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            var bestCol = 0
            var minHeight = colHeights[0]
            if cols > 1 {
                for c in 1..<cols {
                    if colHeights[c] < minHeight - 0.5 {
                        minHeight = colHeights[c]
                        bestCol = c
                    }
                }
            }

            let clampedRatio = effectiveAspectRatio(for: asset, clampedRange: 0.55...2.15)
            let cardHeight = (colWidth / clampedRatio).rounded()
            let x = horizontalPadding + CGFloat(bestCol) * (colWidth + spacing)
            let y = colHeights[bestCol]

            frames.append(MasonryItemFrame(
                id: asset.id,
                index: index,
                rect: CGRect(x: x, y: y, width: colWidth, height: cardHeight)
            ))
            colHeights[bestCol] = y + cardHeight + spacing
        }

        let totalHeight = (colHeights.max() ?? topInset) + bottomInset
        return MasonryLayoutSnapshot(
            items: frames,
            totalHeight: max(totalHeight, 360),
            columnCount: cols,
            columnWidth: colWidth
        )
    }

    /// Horizontal Justified Masonry: packs portrait, square, and landscape assets into equal-height rows
    /// that align flush left-to-right while preserving each asset's natural aspect ratio.
    public static func computeJustified(
        assets: [AssetRecord],
        containerWidth: CGFloat,
        targetRowHeight: CGFloat,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> MasonryLayoutSnapshot {
        let usableWidth = max(240, containerWidth - horizontalPadding * 2)
        let idealRowH = max(104, min(380, targetRowHeight))

        var frames: [MasonryItemFrame] = []
        frames.reserveCapacity(assets.count)

        var row: [(index: Int, id: UUID, ratio: CGFloat)] = []
        var ratioSum: CGFloat = 0
        var cursorY = topInset

        func flushRow(justify: Bool) {
            guard !row.isEmpty else { return }
            let gaps = spacing * CGFloat(row.count - 1)
            let availableForItems = max(60, usableWidth - gaps)
            let rawHeight = justify ? (availableForItems / max(0.1, ratioSum)) : idealRowH
            let rowHeight = max(84, min(idealRowH * 1.48, rawHeight)).rounded()

            var cursorX = horizontalPadding
            for (pos, entry) in row.enumerated() {
                let isLast = (pos == row.count - 1)
                let itemW: CGFloat
                if justify && isLast {
                    itemW = max(44, (horizontalPadding + usableWidth) - cursorX)
                } else {
                    itemW = max(44, (entry.ratio * rowHeight).rounded())
                }
                frames.append(MasonryItemFrame(
                    id: entry.id,
                    index: entry.index,
                    rect: CGRect(x: cursorX, y: cursorY, width: itemW, height: rowHeight)
                ))
                cursorX += itemW + spacing
            }

            cursorY += rowHeight + spacing
            row.removeAll(keepingCapacity: true)
            ratioSum = 0
        }

        for (index, asset) in assets.enumerated() {
            let ratio = effectiveAspectRatio(for: asset, clampedRange: 0.48...2.35)
            let projectedCount = row.count + 1
            let projectedSum = ratioSum + ratio
            let projectedWidth = projectedSum * idealRowH + spacing * CGFloat(projectedCount - 1)

            if !row.isEmpty && projectedWidth > usableWidth {
                // Choose whether breaking before or after this item gives row height closer to idealRowH
                let hBefore = (usableWidth - spacing * CGFloat(row.count - 1)) / max(0.1, ratioSum)
                let hAfter = (usableWidth - spacing * CGFloat(projectedCount - 1)) / max(0.1, projectedSum)
                let errBefore = abs(hBefore - idealRowH)
                let errAfter = abs(hAfter - idealRowH)
                if errAfter < errBefore && hAfter >= idealRowH * 0.68 {
                    row.append((index: index, id: asset.id, ratio: ratio))
                    ratioSum = projectedSum
                    flushRow(justify: true)
                } else {
                    flushRow(justify: true)
                    row.append((index: index, id: asset.id, ratio: ratio))
                    ratioSum = ratio
                }
            } else {
                row.append((index: index, id: asset.id, ratio: ratio))
                ratioSum = projectedSum
            }
        }

        if !row.isEmpty {
            let naturalW = ratioSum * idealRowH + spacing * CGFloat(row.count - 1)
            let shouldJustifyLast = naturalW >= usableWidth * 0.68
            flushRow(justify: shouldJustifyLast)
        }

        let totalHeight = cursorY + bottomInset
        let approxCols = max(1, Int((usableWidth / max(110, idealRowH)).rounded()))
        return MasonryLayoutSnapshot(
            items: frames,
            totalHeight: max(totalHeight, 360),
            columnCount: approxCols,
            columnWidth: idealRowH
        )
    }
}

// MARK: - Context Menu & Interaction Callbacks

public struct MasonryCallbacks {
    public var onOpenQuickLook: (AssetRecord) -> Void
    public var onDropExternalInputs: ([CaptureInput]) -> Void
    public var onAddToMoodboard: ([UUID]) -> Void
    public var onMoveToFolder: ([UUID], UUID?) -> Void
    public var onTogglePinOffline: ([UUID], Bool) -> Void
    public var onCopyColorHex: (String) -> Void
    public var onRevealInFinder: (UUID) -> Void
    public var onCopyAssets: ([UUID]) -> Void
    public var onCutAssets: ([UUID]) -> Void
    public var onPasteIntoCurrentFolder: () -> Void
    public var onExportToPureRef: ([UUID]) -> Void
    public var onOpenInPureRef: ([UUID]) -> Void
    public var onRetagAssets: ([UUID]) -> Void
    public var onTrashAssets: ([UUID]) -> Void
    public var onRestoreAssets: ([UUID]) -> Void
    public var onPermanentlyDeleteAssets: ([UUID]) -> Void
    public var onResolveDragFileURL: (UUID) -> URL?
    public var onZoomColumnWidth: ((CGFloat) -> Void)?

    public init(
        onOpenQuickLook: @escaping (AssetRecord) -> Void = { _ in },
        onDropExternalInputs: @escaping ([CaptureInput]) -> Void = { _ in },
        onAddToMoodboard: @escaping ([UUID]) -> Void = { _ in },
        onMoveToFolder: @escaping ([UUID], UUID?) -> Void = { _, _ in },
        onTogglePinOffline: @escaping ([UUID], Bool) -> Void = { _, _ in },
        onCopyColorHex: @escaping (String) -> Void = { _ in },
        onRevealInFinder: @escaping (UUID) -> Void = { _ in },
        onCopyAssets: @escaping ([UUID]) -> Void = { _ in },
        onCutAssets: @escaping ([UUID]) -> Void = { _ in },
        onPasteIntoCurrentFolder: @escaping () -> Void = {},
        onExportToPureRef: @escaping ([UUID]) -> Void = { _ in },
        onOpenInPureRef: @escaping ([UUID]) -> Void = { _ in },
        onRetagAssets: @escaping ([UUID]) -> Void = { _ in },
        onTrashAssets: @escaping ([UUID]) -> Void = { _ in },
        onRestoreAssets: @escaping ([UUID]) -> Void = { _ in },
        onPermanentlyDeleteAssets: @escaping ([UUID]) -> Void = { _ in },
        onResolveDragFileURL: @escaping (UUID) -> URL? = { _ in nil },
        onZoomColumnWidth: ((CGFloat) -> Void)? = nil
    ) {
        self.onOpenQuickLook = onOpenQuickLook
        self.onDropExternalInputs = onDropExternalInputs
        self.onAddToMoodboard = onAddToMoodboard
        self.onMoveToFolder = onMoveToFolder
        self.onTogglePinOffline = onTogglePinOffline
        self.onCopyColorHex = onCopyColorHex
        self.onRevealInFinder = onRevealInFinder
        self.onCopyAssets = onCopyAssets
        self.onCutAssets = onCutAssets
        self.onPasteIntoCurrentFolder = onPasteIntoCurrentFolder
        self.onExportToPureRef = onExportToPureRef
        self.onOpenInPureRef = onOpenInPureRef
        self.onRetagAssets = onRetagAssets
        self.onTrashAssets = onTrashAssets
        self.onRestoreAssets = onRestoreAssets
        self.onPermanentlyDeleteAssets = onPermanentlyDeleteAssets
        self.onResolveDragFileURL = onResolveDragFileURL
        self.onZoomColumnWidth = onZoomColumnWidth
    }
}

// MARK: - High-FPS Hardware-Accelerated Native AppKit Recycling Masonry View (10k+ Items, 120 FPS)

internal struct MasonryAssetsSignature: Equatable {
    let revision: Int
    let count: Int
    let firstID: UUID?
    let lastID: UUID?
}

public struct MasonryRevealRequest: Equatable, Sendable {
    public let assetID: UUID
    public let nonce: UUID

    public init(assetID: UUID, nonce: UUID = UUID()) {
        self.assetID = assetID
        self.nonce = nonce
    }
}

public struct VirtualizedMasonryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let assets: [AssetRecord]
    public let assetsRevision: Int
    public let folders: [FolderRecord]
    public let loader: ThumbnailImageLoader
    @Binding public var selectedAssetIDs: Set<UUID>
    public let cutAssetIDs: Set<UUID>
    public let layoutMode: GalleryLayoutMode
    public let targetColumnWidth: CGFloat
    public let topContentInset: CGFloat
    public let bottomContentInset: CGFloat
    public let sideChromeWidth: CGFloat?
    public let isLivePaneResizing: Bool
    public let heroNamespace: Namespace.ID
    public let activeQuickLookID: UUID?
    public let isOverlayPresented: Bool
    public let revealRequest: MasonryRevealRequest?
    public let backgroundOverride: Color?
    public let callbacks: MasonryCallbacks

    @State private var isExternalDropTargeted: Bool = false

    public init(
        assets: [AssetRecord],
        assetsRevision: Int = 0,
        folders: [FolderRecord],
        loader: ThumbnailImageLoader,
        selectedAssetIDs: Binding<Set<UUID>>,
        cutAssetIDs: Set<UUID> = [],
        layoutMode: GalleryLayoutMode = .verticalMasonry,
        targetColumnWidth: CGFloat = 228,
        topContentInset: CGFloat = 76,
        bottomContentInset: CGFloat = 96,
        sideChromeWidth: CGFloat? = nil,
        isLivePaneResizing: Bool = false,
        heroNamespace: Namespace.ID,
        activeQuickLookID: UUID? = nil,
        isOverlayPresented: Bool = false,
        revealRequest: MasonryRevealRequest? = nil,
        backgroundOverride: Color? = nil,
        callbacks: MasonryCallbacks = MasonryCallbacks()
    ) {
        self.assets = assets
        self.assetsRevision = assetsRevision
        self.folders = folders
        self.loader = loader
        self._selectedAssetIDs = selectedAssetIDs
        self.cutAssetIDs = cutAssetIDs
        self.layoutMode = layoutMode
        self.targetColumnWidth = targetColumnWidth
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.sideChromeWidth = sideChromeWidth
        self.isLivePaneResizing = isLivePaneResizing
        self.heroNamespace = heroNamespace
        self.activeQuickLookID = activeQuickLookID
        self.isOverlayPresented = isOverlayPresented
        self.revealRequest = revealRequest
        self.backgroundOverride = backgroundOverride
        self.callbacks = callbacks
    }

    public var body: some View {
        let invalidation = loader.invalidationVersion
        ZStack {
            (backgroundOverride ?? CanvasSurface.ground(for: colorScheme))
                .ignoresSafeArea()

            AppKitMasonryRepresentable(
                assets: assets,
                assetsSignature: MasonryAssetsSignature(
                    revision: assetsRevision,
                    count: assets.count,
                    firstID: assets.first?.id,
                    lastID: assets.last?.id
                ),
                folders: folders,
                loader: loader,
                loaderInvalidationVersion: invalidation,
                selectedAssetIDs: $selectedAssetIDs,
                cutAssetIDs: cutAssetIDs,
                layoutMode: layoutMode,
                targetColumnWidth: targetColumnWidth,
                topContentInset: topContentInset,
                bottomContentInset: bottomContentInset,
                sideChromeWidth: sideChromeWidth,
                isLivePaneResizing: isLivePaneResizing,
                activeQuickLookID: activeQuickLookID,
                isOverlayPresented: isOverlayPresented,
                revealRequest: revealRequest,
                isDarkMode: colorScheme == .dark,
                reduceMotion: reduceMotion,
                callbacks: callbacks,
                onExternalDropTargetedChanged: { targeted in
                    if isExternalDropTargeted != targeted {
                        isExternalDropTargeted = targeted
                    }
                }
            )

            CanvasDropRingOverlay(isTargeted: isExternalDropTargeted, padding: 12, fillOpacity: 0.05)
        }
    }
}

// MARK: - NSViewRepresentable Bridge

private struct AppKitMasonryRepresentable: NSViewRepresentable {
    let assets: [AssetRecord]
    let assetsSignature: MasonryAssetsSignature
    let folders: [FolderRecord]
    let loader: ThumbnailImageLoader
    let loaderInvalidationVersion: Int
    @Binding var selectedAssetIDs: Set<UUID>
    let cutAssetIDs: Set<UUID>
    let layoutMode: GalleryLayoutMode
    let targetColumnWidth: CGFloat
    let topContentInset: CGFloat
    let bottomContentInset: CGFloat
    let sideChromeWidth: CGFloat?
    let isLivePaneResizing: Bool
    let activeQuickLookID: UUID?
    let isOverlayPresented: Bool
    let revealRequest: MasonryRevealRequest?
    let isDarkMode: Bool
    let reduceMotion: Bool
    let callbacks: MasonryCallbacks
    let onExternalDropTargetedChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MasonryScrollView {
        let scrollView = MasonryScrollView()
        let doc = scrollView.masonryDocument
        doc.loader = loader
        doc.onSelectionChanged = { [self] newSelection in
            if selectedAssetIDs != newSelection {
                selectedAssetIDs = newSelection
            }
        }
        doc.onExternalDropTargetedChanged = onExternalDropTargetedChanged
        doc.applyState(
            assets: assets,
            signature: assetsSignature,
            folders: folders,
            loaderInvalidationVersion: loaderInvalidationVersion,
            selectedIDs: selectedAssetIDs,
            cutIDs: cutAssetIDs,
            layoutMode: layoutMode,
            targetColumnWidth: targetColumnWidth,
            topInset: topContentInset,
            bottomInset: bottomContentInset,
            sideChromeWidth: sideChromeWidth,
            isLivePaneResizing: isLivePaneResizing,
            activeQuickLookID: activeQuickLookID,
            isOverlayPresented: isOverlayPresented,
            revealRequest: revealRequest,
            isDarkMode: isDarkMode,
            reduceMotion: reduceMotion,
            callbacks: callbacks
        )
        return scrollView
    }

    func updateNSView(_ scrollView: MasonryScrollView, context: Context) {
        let doc = scrollView.masonryDocument
        doc.loader = loader
        doc.onSelectionChanged = { [self] newSelection in
            if selectedAssetIDs != newSelection {
                selectedAssetIDs = newSelection
            }
        }
        doc.onExternalDropTargetedChanged = onExternalDropTargetedChanged
        doc.applyState(
            assets: assets,
            signature: assetsSignature,
            folders: folders,
            loaderInvalidationVersion: loaderInvalidationVersion,
            selectedIDs: selectedAssetIDs,
            cutIDs: cutAssetIDs,
            layoutMode: layoutMode,
            targetColumnWidth: targetColumnWidth,
            topInset: topContentInset,
            bottomInset: bottomContentInset,
            sideChromeWidth: sideChromeWidth,
            isLivePaneResizing: isLivePaneResizing,
            activeQuickLookID: activeQuickLookID,
            isOverlayPresented: isOverlayPresented,
            revealRequest: revealRequest,
            isDarkMode: isDarkMode,
            reduceMotion: reduceMotion,
            callbacks: callbacks
        )
    }

    static func dismantleNSView(_ scrollView: MasonryScrollView, coordinator: ()) {
        scrollView.masonryDocument.releaseOffscreenResources()
    }
}

// MARK: - AppKit Scroll Container (with macOS Photos-Style Pinch & ⌘+Scroll Zoom)

/// Layer-backed clip view with zero resize backing-store redraws, zero implicit CA actions,
/// and strict horizontal origin clamping so animated sidebar/inspector width changes never jitter `bounds.origin.x`.
private final class MasonryClipView: NSClipView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyZeroFlickerLayerConfig()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyZeroFlickerLayerConfig()
    }

    override func makeBackingLayer() -> CALayer {
        let root = super.makeBackingLayer()
        root.actions = MasonryStaticLayerAssets.noImplicitActions
        return root
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyZeroFlickerLayerConfig()
    }

    private func applyZeroFlickerLayerConfig() {
        drawsBackground = false
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.actions = MasonryStaticLayerAssets.noImplicitActions
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.x = 0
        return rect
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }
}

internal final class MasonryScrollView: NSScrollView {
    let masonryDocument = MasonryDocumentView()
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func makeBackingLayer() -> CALayer {
        let root = super.makeBackingLayer()
        root.actions = MasonryStaticLayerAssets.noImplicitActions
        return root
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.actions = MasonryStaticLayerAssets.noImplicitActions
    }

    override func magnify(with event: NSEvent) {
        masonryDocument.handleMagnifyGesture(event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option) {
            // Ignore trailing trackpad momentum so zooming halts crisply when fingers lift
            if !event.momentumPhase.isEmpty { return }
            let isDiscreteWheel = !event.hasPreciseScrollingDeltas
            let rawDelta = isDiscreteWheel ? event.scrollingDeltaY : (event.scrollingDeltaY / 18.0)
            guard abs(rawDelta) > 0.005 else { return }
            let cursorInDoc = masonryDocument.convert(event.locationInWindow, from: nil)
            masonryDocument.handleCommandScrollZoom(
                delta: rawDelta,
                isDiscreteWheel: isDiscreteWheel,
                anchorDocPoint: cursorInDoc,
                cursorWindowPoint: event.locationInWindow
            )
            return
        }
        super.scrollWheel(with: event)
    }

    private func configure() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.actions = MasonryStaticLayerAssets.noImplicitActions
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        let clipView = MasonryClipView(frame: bounds)
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        contentView = clipView
        documentView = masonryDocument

        // Observe AppKit scroll/frame notifications synchronously (`queue: nil`) so tiles mount in the
        // exact display-link commit frame (zero 1-frame fling lag, zero per-tick NSBlockOperation overhead,
        // and deterministic `isProgrammaticZoomScroll` gating).
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.masonryDocument.handleScrollBoundsChanged() }
            } else {
                Task { @MainActor [weak self] in self?.masonryDocument.handleScrollBoundsChanged() }
            }
        })
        observers.append(nc.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.masonryDocument.handleViewportFrameChanged() }
            } else {
                Task { @MainActor [weak self] in self?.masonryDocument.handleViewportFrameChanged() }
            }
        })
        observers.append(nc.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.scrollerStyle = .overlay
                    self?.autohidesScrollers = true
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.scrollerStyle = .overlay
                    self?.autohidesScrollers = true
                }
            }
        })
        observers.append(nc.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: self,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.masonryDocument.setLiveScrolling(true) }
            } else {
                Task { @MainActor [weak self] in self?.masonryDocument.setLiveScrolling(true) }
            }
        })
        observers.append(nc.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: self,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.masonryDocument.setLiveScrolling(false) }
            } else {
                Task { @MainActor [weak self] in self?.masonryDocument.setLiveScrolling(false) }
            }
        })
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - Recycled Core Animation Tile Layer Pool & Static Icon Cache

private final class MasonryCGImageBox {
    let image: CGImage
    let size: CGSize
    init(_ image: CGImage, size: CGSize = .zero) {
        self.image = image
        self.size = size
    }
}

private enum MasonryStaticLayerAssets {
    static let cardSurfaceLightCG: CGColor = NSColor.white.cgColor
    static let cardSurfaceDarkCG: CGColor = NSColor.charkleHex("#1E2024").cgColor
    static let hairlineLightCG: CGColor = NSColor.black.withAlphaComponent(0.08).cgColor
    static let hairlineDarkCG: CGColor = NSColor.white.withAlphaComponent(0.09).cgColor
    static let defaultTintLightCG: CGColor = NSColor.charkleHex("#EAE9E5").withAlphaComponent(0.35).cgColor
    static let defaultTintDarkCG: CGColor = NSColor.charkleHex("#262930").withAlphaComponent(0.35).cgColor

    private static let badgeCache: NSCache<NSString, MasonryCGImageBox> = {
        let c = NSCache<NSString, MasonryCGImageBox>()
        c.countLimit = 64
        c.totalCostLimit = 2 * 1024 * 1024
        return c
    }()
    private static let proceduralCache: NSCache<NSString, MasonryCGImageBox> = {
        let c = NSCache<NSString, MasonryCGImageBox>()
        c.countLimit = 80
        c.totalCostLimit = 16 * 1024 * 1024
        return c
    }()

    static func clearTransientCaches() {
        proceduralCache.removeAllObjects()
        badgeCache.removeAllObjects()
    }

    private static func imageByteCost(_ cg: CGImage) -> Int {
        max(1, max(cg.bytesPerRow * cg.height, cg.width * cg.height * 4))
    }

    static let noImplicitActions: [String: CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "contents": NSNull(),
        "backgroundColor": NSNull(),
        "borderColor": NSNull(),
        "borderWidth": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
        "shadowPath": NSNull(),
        "shadowOpacity": NSNull(),
        "shadowRadius": NSNull(),
        "shadowOffset": NSNull(),
        "path": NSNull(),
        "sublayers": NSNull(),
        "transform": NSNull(),
        "onOrderIn": NSNull(),
        "onOrderOut": NSNull()
    ]

    static func selectedCheckmarkBadge(scale: CGFloat) -> CGImage? {
        let key = "sel-check-\(Int((scale * 10).rounded()))" as NSString
        if let hit = badgeCache.object(forKey: key) { return hit.image }
        let size = CGSize(width: 22, height: 22)
        guard let cg = renderBitmap(size: size, scale: scale, flipped: true, draw: { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()

            if let sym = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                        .applying(.init(paletteColors: [.white]))
                ) {
                let symSize = sym.size
                let target = CGRect(
                    x: (size.width - symSize.width) * 0.5,
                    y: (size.height - symSize.height) * 0.5,
                    width: symSize.width,
                    height: symSize.height
                )
                sym.draw(in: target)
            }
            _ = ctx
        }) else { return nil }
        badgeCache.setObject(MasonryCGImageBox(cg, size: size), forKey: key, cost: imageByteCost(cg))
        return cg
    }

    static func uncheckedHoverBadge(scale: CGFloat) -> CGImage? {
        let key = "hover-check-\(Int((scale * 10).rounded()))" as NSString
        if let hit = badgeCache.object(forKey: key) { return hit.image }
        let size = CGSize(width: 22, height: 22)
        guard let cg = renderBitmap(size: size, scale: scale, flipped: true, draw: { _ in
            let path = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.black.withAlphaComponent(0.42).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.68).setStroke()
            path.lineWidth = 1
            path.stroke()
        }) else { return nil }
        badgeCache.setObject(MasonryCGImageBox(cg, size: size), forKey: key, cost: imageByteCost(cg))
        return cg
    }

    static func pinOfflineBadge(scale: CGFloat) -> CGImage? {
        let key = "pin-badge-\(Int((scale * 10).rounded()))" as NSString
        if let hit = badgeCache.object(forKey: key) { return hit.image }
        let size = CGSize(width: 18, height: 18)
        guard let cg = renderBitmap(size: size, scale: scale, flipped: true, draw: { _ in
            let oval = NSBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
            NSColor.black.withAlphaComponent(0.44).setFill()
            oval.fill()
            NSColor.white.withAlphaComponent(0.20).setStroke()
            oval.lineWidth = 0.5
            oval.stroke()

            if let sym = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                        .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(0.92)]))
                ) {
                let symSize = sym.size
                sym.draw(in: CGRect(
                    x: (size.width - symSize.width) * 0.5,
                    y: (size.height - symSize.height) * 0.5,
                    width: symSize.width,
                    height: symSize.height
                ))
            }
        }) else { return nil }
        badgeCache.setObject(MasonryCGImageBox(cg, size: size), forKey: key, cost: imageByteCost(cg))
        return cg
    }

    static func mediaPillBadge(text: String, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let key = "pill-\(text)-\(Int((scale * 10).rounded()))" as NSString
        if let hit = badgeCache.object(forKey: key) {
            return (hit.image, hit.size)
        }
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pillSize = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 6)
        guard let cg = renderBitmap(size: pillSize, scale: scale, flipped: true, draw: { _ in
            let rect = CGRect(origin: .zero, size: pillSize)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.black.withAlphaComponent(0.56).setFill()
            path.fill()
            (text as NSString).draw(
                at: CGPoint(x: (pillSize.width - textSize.width) * 0.5, y: (pillSize.height - textSize.height) * 0.5),
                withAttributes: attrs
            )
        }) else { return nil }
        badgeCache.setObject(MasonryCGImageBox(cg, size: pillSize), forKey: key, cost: imageByteCost(cg))
        return (cg, pillSize)
    }

    static func cachedProceduralCardImage(for asset: AssetRecord, size: CGSize, isDark: Bool, scale: CGFloat) -> CGImage? {
        let wBucket = max(40, Int((size.width / 8).rounded()) * 8)
        let hBucket = max(40, Int((size.height / 8).rounded()) * 8)
        let key = "\(asset.id.uuidString)-\(asset.title.hashValue)-\(isDark ? 1 : 0)-\(wBucket)x\(hBucket)-\(Int(scale))" as NSString
        return proceduralCache.object(forKey: key)?.image
    }

    static func proceduralCardImage(for asset: AssetRecord, size: CGSize, isDark: Bool, scale: CGFloat) -> CGImage? {
        let wBucket = max(40, Int((size.width / 8).rounded()) * 8)
        let hBucket = max(40, Int((size.height / 8).rounded()) * 8)
        let key = "\(asset.id.uuidString)-\(asset.title.hashValue)-\(isDark ? 1 : 0)-\(wBucket)x\(hBucket)-\(Int(scale))" as NSString
        if let hit = proceduralCache.object(forKey: key) { return hit.image }

        let targetSize = CGSize(width: CGFloat(wBucket), height: CGFloat(hBucket))
        let primaryHex = asset.dominantColors.first?.hex ?? (isDark ? "#2B2F36" : "#DCDAD4")
        let secondaryHex = asset.dominantColors.count > 1 ? asset.dominantColors[1].hex : (isDark ? "#1E2126" : "#EAE8E2")
        let isSwatch = asset.fileName.lowercased().hasSuffix(".swatch")
        let elevatedColor = isDark ? NSColor.charkleHex("#1E2024") : NSColor.white
        let primaryTextColor: NSColor = isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.86)
        let secondaryTextColor: NSColor = isDark ? NSColor.white.withAlphaComponent(0.58) : NSColor.black.withAlphaComponent(0.55)

        guard let cg = renderBitmap(size: targetSize, scale: scale, flipped: true, draw: { ctx in
            let bounds = CGRect(origin: .zero, size: targetSize)
            if isSwatch {
                let bg = NSColor.charkleHex(primaryHex)
                bg.setFill()
                ctx.fill(bounds)
                let light = Color.charkleIsLightHex(primaryHex)
                let hexColor = light ? NSColor.black.withAlphaComponent(0.84) : NSColor.white.withAlphaComponent(0.92)
                let hexStr = primaryHex.uppercased() as NSString
                let hexAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: hexColor
                ]
                hexStr.draw(at: CGPoint(x: 12, y: bounds.height - 32), withAttributes: hexAttrs)
            } else {
                switch asset.mediaKind {
                case .audio:
                    elevatedColor.setFill()
                    ctx.fill(bounds)
                    let accent = NSColor.charkleHex(primaryHex)
                    let peaks: [Float] = asset.waveformPeaks.isEmpty ? (0..<28).map { i in
                        Float(0.22 + 0.65 * sin(Double(i) / 27.0 * .pi))
                    } : asset.waveformPeaks
                    let barCount = min(peaks.count, max(16, Int((bounds.width - 28) / 5.5)))
                    let barW: CGFloat = 3
                    let gap = max(2, (bounds.width - 28 - CGFloat(barCount) * barW) / CGFloat(max(1, barCount - 1)))
                    let midY = bounds.height * 0.48
                    let maxBarH = min(52, bounds.height * 0.36)
                    for i in 0..<barCount {
                        let sample = peaks[i * peaks.count / max(1, barCount)]
                        let amp = max(0.16, min(1.0, CGFloat(sample)))
                        let h = max(4, maxBarH * amp)
                        let rect = CGRect(x: 14 + CGFloat(i) * (barW + gap), y: midY - h * 0.5, width: barW, height: h)
                        accent.withAlphaComponent(0.55 + amp * 0.45).setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
                    }
                    let titleAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: primaryTextColor
                    ]
                    (asset.title as NSString).draw(
                        in: CGRect(x: 14, y: bounds.height - 28, width: bounds.width - 28, height: 18),
                        withAttributes: titleAttrs
                    )
                case .webBookmark, .document, .designFile, .model3D:
                    elevatedColor.setFill()
                    ctx.fill(bounds)
                    let accent = NSColor.charkleHex(primaryHex)
                    accent.withAlphaComponent(0.82).setFill()
                    ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 3))
                    let badge: String = {
                        if asset.isGitHubRepo { return "GITHUB" }
                        if let post = asset.richMetadata?.socialPost { return post.displayHandleLine ?? post.authorName }
                        if asset.mediaKind == .model3D { return "3D · \(asset.richMetadata?.model3DFormat ?? "MODEL")" }
                        return asset.mediaKind == .webBookmark
                            ? (asset.sourceDomain ?? "web.link")
                            : CanvasFormatters.fileExtensionBadge(for: asset.fileName)
                    }()
                    let badgeAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                        .foregroundColor: secondaryTextColor
                    ]
                    (badge as NSString).draw(at: CGPoint(x: 14, y: 14), withAttributes: badgeAttrs)

                    let para = NSMutableParagraphStyle()
                    para.lineBreakMode = .byTruncatingTail
                    let titleAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                        .foregroundColor: primaryTextColor,
                        .paragraphStyle: para
                    ]
                    (asset.title as NSString).draw(
                        in: CGRect(x: 14, y: max(38, bounds.height - 62), width: bounds.width - 28, height: 48),
                        withAttributes: titleAttrs
                    )
                case .image, .animatedImage, .video:
                    let gradient = NSGradient(
                        starting: NSColor.charkleHex(primaryHex).withAlphaComponent(0.88),
                        ending: NSColor.charkleHex(secondaryHex).withAlphaComponent(0.95)
                    )
                    gradient?.draw(in: bounds, angle: 135)
                }
            }
        }) else { return nil }

        proceduralCache.setObject(MasonryCGImageBox(cg, size: targetSize), forKey: key, cost: imageByteCost(cg))
        return cg
    }

    static func renderHoverCaption(title: String, rating: Int, width: CGFloat, scale: CGFloat) -> CGImage? {
        let height: CGFloat = 34
        let size = CGSize(width: max(40, ceil(width)), height: height)
        return renderBitmap(size: size, scale: scale, flipped: true, draw: { _ in
            let rect = CGRect(origin: .zero, size: size)
            let grad = NSGradient(
                starting: NSColor.clear,
                ending: NSColor.black.withAlphaComponent(0.64)
            )
            grad?.draw(in: rect, angle: 90)

            let rightReserve: CGFloat = rating > 0 ? 34 : 10
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: para
            ]
            (title as NSString).draw(
                in: CGRect(x: 10, y: 12, width: max(20, size.width - 10 - rightReserve), height: 16),
                withAttributes: titleAttrs
            )

            if rating > 0 {
                let starText = "★\(rating)" as NSString
                let starAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.charkleHex("#F2C14E")
                ]
                let starSize = starText.size(withAttributes: starAttrs)
                starText.draw(
                    at: CGPoint(x: size.width - 10 - starSize.width, y: 13),
                    withAttributes: starAttrs
                )
            }
        })
    }

    private static func renderBitmap(size: CGSize, scale: CGFloat, flipped: Bool, draw: (CGContext) -> Void) -> CGImage? {
        let s = max(1, scale)
        let pxW = max(1, Int((size.width * s).rounded()))
        let pxH = max(1, Int((size.height * s).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.scaleBy(x: s, y: s)
        if flipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: flipped)
        draw(ctx)
        NSGraphicsContext.current = prev
        return ctx.makeImage()
    }
}

private final class MasonryTileLayer {
    private static let cornerRad: CGFloat = 12

    let layer = CALayer()
    var boundAssetID: UUID?
    var boundAsset: AssetRecord?
    var loadTask: Task<Void, Never>?
    private var lastShadowSize: CGSize = .zero
    private var lastBadgeText: String?
    private var lastBadgeScale: CGFloat = 0
    private var isShowingProceduralImage: Bool = false
    var needsDeferredProceduralRender: Bool = false
    private var lastProceduralKey: String?

    private var hasVisualState: Bool = false
    private var lastVisualSelected: Bool = false
    private var lastVisualCut: Bool = false
    private var lastVisualHidden: Bool = false
    private var lastVisualDark: Bool = false
    private var lastVisualScale: CGFloat = 0

    // Lean 3-layer baseline (`layer` -> `imageLayer` + `borderLayer`); overlay & shape layers
    // are allocated lazily ONLY when needed, cutting per-tile CoreAnimation layer count by 62.5%.
    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private var cutDashLayer: CAShapeLayer?
    private var selectedCheckLayer: CALayer?
    private var pinBadgeLayer: CALayer?
    private var mediaBadgeLayer: CALayer?

    var sublayerCountForTesting: Int {
        layer.sublayers?.count ?? 0
    }

    var hasImageContentsForTesting: Bool {
        imageLayer.contents != nil
    }

    init() {
        setupSublayers()
    }

    isolated deinit {
        loadTask?.cancel()
    }

    private func setupSublayers() {
        layer.actions = MasonryStaticLayerAssets.noImplicitActions
        layer.masksToBounds = false
        layer.cornerRadius = Self.cornerRad
        layer.cornerCurve = .continuous
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 4
        layer.shadowOpacity = 0.07

        // Clip directly on imageLayer (zero intermediate clipLayer) and use `.linear`
        // minification to avoid CoreAnimation's +33% trilinear mipmap backing-store bloat.
        imageLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        imageLayer.cornerRadius = Self.cornerRad
        imageLayer.cornerCurve = .continuous
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.minificationFilter = .linear
        imageLayer.magnificationFilter = .linear
        layer.addSublayer(imageLayer)

        borderLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        borderLayer.cornerRadius = Self.cornerRad
        borderLayer.cornerCurve = .continuous
        borderLayer.backgroundColor = nil
        layer.addSublayer(borderLayer)
    }

    private func ensureSelectedCheckLayer() -> CALayer {
        if let existing = selectedCheckLayer { return existing }
        let sub = CALayer()
        sub.actions = MasonryStaticLayerAssets.noImplicitActions
        sub.contentsGravity = .resizeAspect
        layer.addSublayer(sub)
        selectedCheckLayer = sub
        return sub
    }

    private func ensurePinBadgeLayer() -> CALayer {
        if let existing = pinBadgeLayer { return existing }
        let sub = CALayer()
        sub.actions = MasonryStaticLayerAssets.noImplicitActions
        sub.contentsGravity = .resizeAspect
        layer.addSublayer(sub)
        pinBadgeLayer = sub
        return sub
    }

    private func ensureMediaBadgeLayer() -> CALayer {
        if let existing = mediaBadgeLayer { return existing }
        let sub = CALayer()
        sub.actions = MasonryStaticLayerAssets.noImplicitActions
        sub.contentsGravity = .resizeAspect
        layer.addSublayer(sub)
        mediaBadgeLayer = sub
        return sub
    }

    private func ensureCutDashLayer(bounds localBounds: CGRect) -> CAShapeLayer {
        if let existing = cutDashLayer { return existing }
        let sub = CAShapeLayer()
        sub.actions = MasonryStaticLayerAssets.noImplicitActions
        sub.fillColor = nil
        sub.lineWidth = 1.25
        sub.lineDashPattern = [5, 4]
        sub.frame = localBounds
        sub.path = CGPath(roundedRect: localBounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
        layer.addSublayer(sub)
        cutDashLayer = sub
        return sub
    }

    var frame: CGRect {
        layer.frame
    }

    func prepareForReuse() {
        loadTask?.cancel()
        loadTask = nil
        stripLayoutAnimations()
        layer.zPosition = 0
        boundAssetID = nil
        boundAsset = nil
        imageLayer.contents = nil
        imageLayer.opacity = 1.0

        selectedCheckLayer?.contents = nil
        selectedCheckLayer?.removeFromSuperlayer()
        selectedCheckLayer = nil

        pinBadgeLayer?.contents = nil
        pinBadgeLayer?.removeFromSuperlayer()
        pinBadgeLayer = nil

        mediaBadgeLayer?.contents = nil
        mediaBadgeLayer?.removeFromSuperlayer()
        mediaBadgeLayer = nil

        cutDashLayer?.path = nil
        cutDashLayer?.removeFromSuperlayer()
        cutDashLayer = nil

        lastBadgeText = nil
        isShowingProceduralImage = false
        needsDeferredProceduralRender = false
        lastProceduralKey = nil
        hasVisualState = false
    }

    func stripLayoutAnimations() {
        layer.removeAnimation(forKey: "charkle.pos")
        layer.removeAnimation(forKey: "charkle.bounds")
        layer.removeAnimation(forKey: "charkle.shadowPath")
        layer.removeAnimation(forKey: "charkle.enterScale")
        layer.removeAnimation(forKey: "charkle.enterOpacity")
        layer.removeAnimation(forKey: "charkle.revealPulse")
        borderLayer.removeAnimation(forKey: "charkle.revealBorder")
        imageLayer.removeAnimation(forKey: "charkle.pos")
        imageLayer.removeAnimation(forKey: "charkle.bounds")
        borderLayer.removeAnimation(forKey: "charkle.pos")
        borderLayer.removeAnimation(forKey: "charkle.bounds")
        mediaBadgeLayer?.removeAnimation(forKey: "charkle.pos")
        pinBadgeLayer?.removeAnimation(forKey: "charkle.pos")
        cutDashLayer?.removeAnimation(forKey: "charkle.pos")
        cutDashLayer?.removeAnimation(forKey: "charkle.bounds")
        cutDashLayer?.removeAnimation(forKey: "charkle.path")
    }

    /// GPU-composited Photos-style transition from a scroll/transform-compensated `fromRect` to `newRect`.
    /// Animates card frame, image clip, border, shadow, and right-edge badges in unison with zero jump.
    func animateFrameTransition(
        from fromRect: CGRect,
        to newRect: CGRect,
        duration: CFTimeInterval = 0.28,
        timingFunction: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)
    ) {
        stripLayoutAnimations()
        guard fromRect != newRect, fromRect.width > 1, fromRect.height > 1 else { return }
        let timing = timingFunction

        let fromPos = CGPoint(x: fromRect.midX, y: fromRect.midY)
        let toPos = CGPoint(x: newRect.midX, y: newRect.midY)
        let fromBounds = CGRect(origin: .zero, size: fromRect.size)
        let toBounds = CGRect(origin: .zero, size: newRect.size)

        func addPair(on target: CALayer, fromP: CGPoint, toP: CGPoint, fromB: CGRect, toB: CGRect) {
            if abs(fromP.x - toP.x) > 0.25 || abs(fromP.y - toP.y) > 0.25 {
                let posAnim = CABasicAnimation(keyPath: "position")
                posAnim.fromValue = fromP
                posAnim.toValue = toP
                posAnim.duration = duration
                posAnim.timingFunction = timing
                target.add(posAnim, forKey: "charkle.pos")
            }
            if abs(fromB.width - toB.width) > 0.25 || abs(fromB.height - toB.height) > 0.25 {
                let bAnim = CABasicAnimation(keyPath: "bounds")
                bAnim.fromValue = fromB
                bAnim.toValue = toB
                bAnim.duration = duration
                bAnim.timingFunction = timing
                target.add(bAnim, forKey: "charkle.bounds")
            }
        }

        addPair(on: layer, fromP: fromPos, toP: toPos, fromB: fromBounds, toB: toBounds)

        let fromLocalCenter = CGPoint(x: fromBounds.midX, y: fromBounds.midY)
        let toLocalCenter = CGPoint(x: toBounds.midX, y: toBounds.midY)
        addPair(on: imageLayer, fromP: fromLocalCenter, toP: toLocalCenter, fromB: fromBounds, toB: toBounds)
        addPair(on: borderLayer, fromP: fromLocalCenter, toP: toLocalCenter, fromB: fromBounds, toB: toBounds)

        if abs(fromBounds.width - toBounds.width) > 0.25 || abs(fromBounds.height - toBounds.height) > 0.25 {
            let shadowAnim = CABasicAnimation(keyPath: "shadowPath")
            shadowAnim.fromValue = CGPath(roundedRect: fromBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            shadowAnim.toValue = CGPath(roundedRect: toBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            shadowAnim.duration = duration
            shadowAnim.timingFunction = timing
            layer.add(shadowAnim, forKey: "charkle.shadowPath")

            if let cutLayer = cutDashLayer, !cutLayer.isHidden {
                addPair(on: cutLayer, fromP: fromLocalCenter, toP: toLocalCenter, fromB: fromBounds, toB: toBounds)
                let pathAnim = CABasicAnimation(keyPath: "path")
                pathAnim.fromValue = CGPath(roundedRect: fromBounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
                pathAnim.toValue = CGPath(roundedRect: toBounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
                pathAnim.duration = duration
                pathAnim.timingFunction = timing
                cutLayer.add(pathAnim, forKey: "charkle.path")
            }

            // Keep top-right badges anchored to the card edge during bounds resize
            let deltaW = toBounds.width - fromBounds.width
            if abs(deltaW) > 0.5 {
                if let badge = mediaBadgeLayer, !badge.isHidden {
                    let badgeTo = badge.position
                    let badgeAnim = CABasicAnimation(keyPath: "position")
                    badgeAnim.fromValue = CGPoint(x: badgeTo.x - deltaW, y: badgeTo.y)
                    badgeAnim.toValue = badgeTo
                    badgeAnim.duration = duration
                    badgeAnim.timingFunction = timing
                    badge.add(badgeAnim, forKey: "charkle.pos")
                }
                if let pin = pinBadgeLayer, !pin.isHidden {
                    let pinTo = pin.position
                    let pinAnim = CABasicAnimation(keyPath: "position")
                    pinAnim.fromValue = CGPoint(x: pinTo.x - deltaW, y: pinTo.y)
                    pinAnim.toValue = pinTo
                    pinAnim.duration = duration
                    pinAnim.timingFunction = timing
                    pin.add(pinAnim, forKey: "charkle.pos")
                }
            }
        }
    }

    /// Quiet Photos-style crossfade settle (`scale(0.96 -> 1.0)` + `opacity(fromOpacity -> 1)`) used for newly visible cards
    /// and for cards whose column wrap would otherwise shoot wildly across the entire screen.
    func animateEnter(
        duration: CFTimeInterval = 0.22,
        fromOpacity: Float = 0.0,
        fromScale: CGFloat = 0.96,
        timingFunction: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)
    ) {
        stripLayoutAnimations()
        let timing = timingFunction
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = fromScale
        scaleAnim.toValue = 1.0
        scaleAnim.duration = duration
        scaleAnim.timingFunction = timing
        layer.add(scaleAnim, forKey: "charkle.enterScale")

        let opAnim = CABasicAnimation(keyPath: "opacity")
        opAnim.fromValue = fromOpacity
        opAnim.toValue = 1.0
        opAnim.duration = duration * 0.85
        opAnim.timingFunction = timing
        layer.add(opAnim, forKey: "charkle.enterOpacity")
    }

    /// Brief tactile spotlight pulse used when jumping from a Moodboard or Quick Jump directly to this asset.
    func animateRevealSpotlight(reduceMotion: Bool) {
        let borderPulse = CAKeyframeAnimation(keyPath: "borderWidth")
        borderPulse.values = [2.5, 4.2, 2.5]
        borderPulse.keyTimes = [0, 0.38, 1.0]
        borderPulse.duration = reduceMotion ? 0.25 : 0.62
        borderPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderLayer.add(borderPulse, forKey: "charkle.revealBorder")

        guard !reduceMotion else { return }
        let scalePulse = CAKeyframeAnimation(keyPath: "transform.scale")
        scalePulse.values = [1.0, 1.032, 1.0]
        scalePulse.keyTimes = [0, 0.35, 1.0]
        scalePulse.duration = 0.46
        scalePulse.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        layer.add(scalePulse, forKey: "charkle.revealPulse")
    }

    /// Fast geometry-only frame update used during sidebar/inspector drawer animations and live window resize,
    /// avoiding redundant selection, badge, color, and thumbnail cache work on every frame.
    func updateFrameOnly(_ rect: CGRect) {
        layer.frame = rect
        let localBounds = CGRect(origin: .zero, size: rect.size)
        imageLayer.frame = localBounds
        borderLayer.frame = localBounds

        if lastShadowSize != rect.size {
            lastShadowSize = rect.size
            layer.shadowPath = CGPath(roundedRect: localBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            if let cutLayer = cutDashLayer {
                cutLayer.frame = localBounds
                cutLayer.path = CGPath(roundedRect: localBounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            }
        }

        var rightCursor = rect.width - 6
        if let badge = mediaBadgeLayer, !badge.isHidden {
            let w = badge.bounds.width
            let h = badge.bounds.height
            badge.frame = CGRect(x: rightCursor - w, y: 6, width: w, height: h)
            rightCursor -= (w + 4)
        }
        if let pin = pinBadgeLayer, !pin.isHidden {
            pin.frame = CGRect(x: rightCursor - 18, y: 6, width: 18, height: 18)
        }
    }

    func configure(
        asset: AssetRecord,
        frame rect: CGRect,
        isSelected: Bool,
        isCut: Bool,
        isHiddenForHero: Bool,
        isDark: Bool,
        scale: CGFloat,
        loader: ThumbnailImageLoader?,
        forceReloadImage: Bool,
        isLiveScrolling: Bool = false
    ) {
        let sameAsset = (boundAssetID == asset.id)
        boundAssetID = asset.id
        boundAsset = asset
        if layer.contentsScale != scale {
            layer.contentsScale = scale
            imageLayer.contentsScale = scale
        }

        layer.frame = rect
        let localBounds = CGRect(origin: .zero, size: rect.size)
        imageLayer.frame = localBounds
        borderLayer.frame = localBounds

        let cardSurfaceCG = isDark ? MasonryStaticLayerAssets.cardSurfaceDarkCG : MasonryStaticLayerAssets.cardSurfaceLightCG
        layer.backgroundColor = cardSurfaceCG

        if lastShadowSize != rect.size {
            lastShadowSize = rect.size
            layer.shadowPath = CGPath(roundedRect: localBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            if let cutLayer = cutDashLayer {
                cutLayer.frame = localBounds
                cutLayer.path = CGPath(roundedRect: localBounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            }
        }

        // Selection & cut visuals
        let scaleChanged = abs(lastBadgeScale - scale) > 0.01
        updateVisualStates(isSelected: isSelected, isCut: isCut, isHiddenForHero: isHiddenForHero, isDark: isDark, scale: scale)

        // Badges (top-right, lazily instantiated)
        var rightCursor = rect.width - 6
        let badgeText = Self.mediaBadgeText(for: asset)
        if let badgeText {
            let badgeLayer = ensureMediaBadgeLayer()
            if lastBadgeText != badgeText || badgeLayer.contents == nil || scaleChanged,
               let pill = MasonryStaticLayerAssets.mediaPillBadge(text: badgeText, scale: scale) {
                badgeLayer.contents = pill.image
                badgeLayer.contentsScale = scale
                badgeLayer.frame = CGRect(x: rightCursor - pill.size.width, y: 6, width: pill.size.width, height: pill.size.height)
                lastBadgeText = badgeText
            } else {
                let w = badgeLayer.bounds.width
                let h = badgeLayer.bounds.height
                badgeLayer.frame = CGRect(x: rightCursor - w, y: 6, width: w, height: h)
            }
            badgeLayer.isHidden = false
            rightCursor -= (badgeLayer.frame.width + 4)
        } else if let badgeLayer = mediaBadgeLayer {
            badgeLayer.contents = nil
            badgeLayer.removeFromSuperlayer()
            mediaBadgeLayer = nil
            lastBadgeText = nil
        }

        if asset.pinnedOffline {
            let pinLayer = ensurePinBadgeLayer()
            if pinLayer.contents == nil || scaleChanged {
                pinLayer.contents = MasonryStaticLayerAssets.pinOfflineBadge(scale: scale)
                pinLayer.contentsScale = scale
            }
            pinLayer.frame = CGRect(x: rightCursor - 18, y: 6, width: 18, height: 18)
            pinLayer.isHidden = false
        } else if let pinLayer = pinBadgeLayer {
            pinLayer.contents = nil
            pinLayer.removeFromSuperlayer()
            pinBadgeLayer = nil
        }
        lastBadgeScale = scale

        // Thumbnail image (synchronous zero-bridging CGImage fast path -> async off-main-thread fallback)
        // Only compute proceduralKey String when displaying or falling back to a procedural card.
        func makeProceduralKey() -> String {
            "\(asset.id.uuidString)-\(asset.title.hashValue)-\(asset.dominantColors.first?.hex ?? "")-\(isDark ? 1 : 0)-\(Int((scale * 10).rounded()))"
        }

        let proceduralNeedsRefresh: Bool
        let computedProceduralKey: String?
        if isShowingProceduralImage {
            let key = makeProceduralKey()
            computedProceduralKey = key
            proceduralNeedsRefresh = (lastProceduralKey != key)
        } else {
            computedProceduralKey = nil
            proceduralNeedsRefresh = false
        }
        guard !sameAsset || forceReloadImage || imageLayer.contents == nil || proceduralNeedsRefresh else { return }

        // Keep a valid in-flight thumbnail decode running on non-forced reconfigures (e.g. scroll settle)
        // unless this tile still needs its deferred procedural fallback rendered.
        if sameAsset && !forceReloadImage && !proceduralNeedsRefresh && !needsDeferredProceduralRender && loadTask != nil && imageLayer.contents == nil {
            return
        }

        if proceduralNeedsRefresh && sameAsset && !forceReloadImage {
            if let cached = loader?.cachedCGImage(for: asset.id, tier: .grid520) {
                imageLayer.backgroundColor = cardSurfaceCG
                imageLayer.contents = cached
                isShowingProceduralImage = false
                lastProceduralKey = nil
            } else {
                imageLayer.contents = MasonryStaticLayerAssets.proceduralCardImage(for: asset, size: rect.size, isDark: isDark, scale: scale)
                isShowingProceduralImage = true
                lastProceduralKey = computedProceduralKey
            }
            return
        }

        loadTask?.cancel()
        loadTask = nil

        if let cached = loader?.cachedCGImage(for: asset.id, tier: .grid520) {
            imageLayer.backgroundColor = cardSurfaceCG
            imageLayer.contents = cached
            isShowingProceduralImage = false
            lastProceduralKey = nil
            return
        }

        // Immediate zero-CPU placeholder tint (or procedural card for non-raster kinds)
        let isProceduralKind = asset.fileName.lowercased().hasSuffix(".swatch")
            || asset.mediaKind == .audio
            || asset.mediaKind == .webBookmark
            || asset.mediaKind == .document
            || asset.mediaKind == .designFile
            || asset.mediaKind == .model3D

        if isProceduralKind {
            if let cachedProc = MasonryStaticLayerAssets.cachedProceduralCardImage(for: asset, size: rect.size, isDark: isDark, scale: scale) {
                imageLayer.contents = cachedProc
                isShowingProceduralImage = true
                needsDeferredProceduralRender = false
                lastProceduralKey = computedProceduralKey ?? makeProceduralKey()
            } else if isLiveScrolling {
                // During 120Hz live flings, avoid main-thread CoreText procedural rasterization on cache miss;
                // show tint immediately and render fallback once live scroll settles if no thumbnail exists.
                if let tintHex = asset.dominantColors.first?.hex {
                    imageLayer.backgroundColor = NSColor.charkleHex(tintHex).withAlphaComponent(0.35).cgColor
                } else {
                    imageLayer.backgroundColor = isDark ? MasonryStaticLayerAssets.defaultTintDarkCG : MasonryStaticLayerAssets.defaultTintLightCG
                }
                imageLayer.contents = nil
                isShowingProceduralImage = false
                needsDeferredProceduralRender = true
                lastProceduralKey = nil
            } else {
                imageLayer.contents = MasonryStaticLayerAssets.proceduralCardImage(for: asset, size: rect.size, isDark: isDark, scale: scale)
                isShowingProceduralImage = true
                needsDeferredProceduralRender = false
                lastProceduralKey = computedProceduralKey ?? makeProceduralKey()
            }
        } else {
            needsDeferredProceduralRender = false
            if let tintHex = asset.dominantColors.first?.hex {
                imageLayer.backgroundColor = NSColor.charkleHex(tintHex).withAlphaComponent(0.35).cgColor
            } else {
                imageLayer.backgroundColor = isDark ? MasonryStaticLayerAssets.defaultTintDarkCG : MasonryStaticLayerAssets.defaultTintLightCG
            }
            imageLayer.contents = nil
            isShowingProceduralImage = false
            lastProceduralKey = nil
        }

        guard let loader else { return }
        let targetID = asset.id
        let targetSize = rect.size
        loadTask = Task { [weak self] in
            let cg = await loader.loadCGImage(for: targetID, tier: .grid520)
            guard !Task.isCancelled, let self, self.boundAssetID == targetID else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let cg {
                self.imageLayer.contents = cg
                self.imageLayer.backgroundColor = cardSurfaceCG
                self.isShowingProceduralImage = false
                self.needsDeferredProceduralRender = false
                self.lastProceduralKey = nil
            } else if self.imageLayer.contents == nil {
                self.imageLayer.contents = MasonryStaticLayerAssets.proceduralCardImage(
                    for: asset,
                    size: targetSize,
                    isDark: isDark,
                    scale: scale
                )
                self.isShowingProceduralImage = true
                self.needsDeferredProceduralRender = false
                self.lastProceduralKey = makeProceduralKey()
            }
            CATransaction.commit()
        }
    }

    func updateVisualStates(isSelected: Bool, isCut: Bool, isHiddenForHero: Bool, isDark: Bool, scale: CGFloat) {
        let scaleSame = abs(lastVisualScale - scale) <= 0.01
        if hasVisualState
            && lastVisualSelected == isSelected
            && lastVisualCut == isCut
            && lastVisualHidden == isHiddenForHero
            && lastVisualDark == isDark
            && scaleSame {
            return
        }
        hasVisualState = true
        lastVisualSelected = isSelected
        lastVisualCut = isCut
        lastVisualHidden = isHiddenForHero
        lastVisualDark = isDark
        lastVisualScale = scale

        imageLayer.opacity = isHiddenForHero ? 0.0 : (isCut ? 0.52 : 1.0)
        if isSelected {
            borderLayer.borderColor = NSColor.controlAccentColor.cgColor
            borderLayer.borderWidth = 2.5
            layer.shadowOpacity = isDark ? 0.34 : 0.14
            layer.shadowRadius = 8
            layer.shadowOffset = CGSize(width: 0, height: 3)
            let checkLayer = ensureSelectedCheckLayer()
            if checkLayer.contents == nil || abs(checkLayer.contentsScale - scale) > 0.01 {
                checkLayer.contents = MasonryStaticLayerAssets.selectedCheckmarkBadge(scale: scale)
                checkLayer.contentsScale = scale
            }
            checkLayer.frame = CGRect(x: 6, y: 6, width: 22, height: 22)
            checkLayer.isHidden = false
        } else {
            borderLayer.borderColor = isDark ? MasonryStaticLayerAssets.hairlineDarkCG : MasonryStaticLayerAssets.hairlineLightCG
            borderLayer.borderWidth = 0.75
            layer.shadowOpacity = isDark ? 0.22 : 0.06
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
            if let checkLayer = selectedCheckLayer {
                checkLayer.contents = nil
                checkLayer.removeFromSuperlayer()
                selectedCheckLayer = nil
            }
        }

        if isCut {
            let cutLayer = ensureCutDashLayer(bounds: CGRect(origin: .zero, size: layer.bounds.size))
            cutLayer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65).cgColor
            cutLayer.isHidden = false
        } else if let cutLayer = cutDashLayer {
            cutLayer.path = nil
            cutLayer.removeFromSuperlayer()
            cutDashLayer = nil
        }
    }

    private static func mediaBadgeText(for asset: AssetRecord) -> String? {
        switch asset.mediaKind {
        case .image:
            return nil
        case .animatedImage:
            return "GIF"
        case .video:
            return CanvasFormatters.durationString(asset.durationSeconds)
        case .audio:
            return "AUDIO"
        case .webBookmark:
            if asset.isGitHubRepo { return "GITHUB" }
            if let post = asset.richMetadata?.socialPost { return post.platform.displayName.uppercased() }
            return "WEB"
        case .document:
            return asset.fileName.lowercased().hasSuffix(".swatch") ? nil : CanvasFormatters.fileExtensionBadge(for: asset.fileName)
        case .designFile:
            return CanvasFormatters.fileExtensionBadge(for: asset.fileName)
        case .model3D:
            return asset.richMetadata?.model3DFormat ?? "3D"
        }
    }
}

// MARK: - Single Shared Hover Overlay Layer (Zero Per-Card Hover Subtree Overhead)

private final class MasonryHoverOverlayLayer {
    let layer = CALayer()
    private let scrimLayer = CALayer()
    private let checkboxLayer = CALayer()
    private let captionLayer = CALayer()
    private var lastCaptionKey: String = ""

    var isHidden: Bool { layer.isHidden }

    init() {
        setup()
    }

    private func setup() {
        layer.actions = MasonryStaticLayerAssets.noImplicitActions
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.zPosition = 500
        layer.isHidden = true

        scrimLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        layer.addSublayer(scrimLayer)

        checkboxLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        checkboxLayer.contentsGravity = .resizeAspect
        layer.addSublayer(checkboxLayer)

        captionLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        captionLayer.contentsGravity = .resize
        layer.addSublayer(captionLayer)
    }

    func show(for asset: AssetRecord, in rect: CGRect, isSelected: Bool, isDark: Bool, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = rect
        let localBounds = CGRect(origin: .zero, size: rect.size)

        scrimLayer.frame = localBounds
        scrimLayer.backgroundColor = NSColor.white.withAlphaComponent(isSelected ? 0.0 : (isDark ? 0.05 : 0.06)).cgColor

        if isSelected {
            checkboxLayer.isHidden = true
        } else {
            if checkboxLayer.contents == nil || abs(checkboxLayer.contentsScale - scale) > 0.01 {
                checkboxLayer.contents = MasonryStaticLayerAssets.uncheckedHoverBadge(scale: scale)
                checkboxLayer.contentsScale = scale
            }
            checkboxLayer.frame = CGRect(x: 6, y: 6, width: 22, height: 22)
            checkboxLayer.isHidden = false
        }

        let showCaption = asset.mediaKind == .image || asset.mediaKind == .animatedImage || asset.mediaKind == .video
        if showCaption {
            let capKey = "\(asset.id.uuidString)-\(asset.title)-\(asset.rating)-\(Int(rect.width))-\(Int(scale))"
            if capKey != lastCaptionKey {
                captionLayer.contents = MasonryStaticLayerAssets.renderHoverCaption(
                    title: asset.title,
                    rating: asset.rating,
                    width: rect.width,
                    scale: scale
                )
                captionLayer.contentsScale = scale
                lastCaptionKey = capKey
            }
            captionLayer.frame = CGRect(x: 0, y: rect.height - 34, width: rect.width, height: 34)
            captionLayer.isHidden = false
        } else {
            captionLayer.isHidden = true
        }

        layer.isHidden = false
        CATransaction.commit()
    }

    func hide() {
        guard !layer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }

    func releaseContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        checkboxLayer.contents = nil
        captionLayer.contents = nil
        lastCaptionKey = ""
        CATransaction.commit()
    }
}

// MARK: - Read-Only Source-Card Geometry Reporter (Quick Look Connected Motion)

/// Read-only registry reporting the current visible window-space frame (top-left origin,
/// matching SwiftUI full-bleed window coordinates) of a gallery card for Quick Look transitions.
/// Tracks all mounted `MasonryDocumentView`s weakly so secondary panels (e.g. Notch Shelf)
/// never clobber the primary workspace window's geometry lookup.
public final class MasonryCardGeometryRegistry {
    public static let shared = MasonryCardGeometryRegistry()

    private let mountedViews = NSHashTable<MasonryDocumentView>.weakObjects()

    private init() {}

    fileprivate func register(_ view: MasonryDocumentView) {
        mountedViews.add(view)
    }

    fileprivate func unregister(_ view: MasonryDocumentView) {
        mountedViews.remove(view)
    }

    internal var registeredCountForTesting: Int {
        mountedViews.allObjects.count
    }

    /// Returns the card's frame in top-left window content coordinates when the card intersects
    /// the active gallery viewport; prefers the main non-panel workspace window over auxiliary panels.
    public func visibleCardRectInWindow(for assetID: UUID) -> CGRect? {
        let views = mountedViews.allObjects
        guard !views.isEmpty else { return nil }

        // 1. Prefer the active main workspace window (never an NSPanel like Notch Shelf)
        if let mainWin = NSApp?.mainWindow, !(mainWin is NSPanel) {
            for view in views where view.window === mainWin {
                if let rect = view.visibleCardRectInWindow(for: assetID) {
                    return rect
                }
            }
        }
        // 2. Prefer key non-panel window
        if let keyWin = NSApp?.keyWindow, !(keyWin is NSPanel) {
            for view in views where view.window === keyWin {
                if let rect = view.visibleCardRectInWindow(for: assetID) {
                    return rect
                }
            }
        }
        // 3. Any mounted non-panel window
        for view in views where view.window != nil && !(view.window is NSPanel) {
            if let rect = view.visibleCardRectInWindow(for: assetID) {
                return rect
            }
        }
        // 4. Fallback to any mounted view (e.g., standalone panel or test window)
        for view in views {
            if let rect = view.visibleCardRectInWindow(for: assetID) {
                return rect
            }
        }
        return nil
    }
}

// MARK: - Menu Action Closure Helper

private final class MasonryMenuActionTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func performAction() { handler() }
}

// MARK: - Native Flipped Layer-Backed Recycling Document View

internal final class MasonryDocumentView: NSView, NSDraggingSource {
    /// `nonisolated` is mandatory under Swift 6: AppKit calls `isFlipped` concurrently via
    /// `dispatch_apply` during multi-item `beginDraggingSession(with:event:source:)`.
    override nonisolated var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Pure `CALayer` sublayer host: prevents AppKit from ever allocating a backing store
    /// for tall (100,000pt+) virtualized document frames.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    weak var loader: ThumbnailImageLoader?
    var onSelectionChanged: ((Set<UUID>) -> Void)?
    var onExternalDropTargetedChanged: ((Bool) -> Void)?

    private var assets: [AssetRecord] = []
    private var assetsSignature = MasonryAssetsSignature(revision: -1, count: -1, firstID: nil, lastID: nil)
    private var assetIndexByID: [UUID: Int] = [:]
    private var folders: [FolderRecord] = []
    private var loaderInvalidationVersion: Int = -1
    private var selectedAssetIDs: Set<UUID> = []
    private var cutAssetIDs: Set<UUID> = []
    private var layoutMode: GalleryLayoutMode = .verticalMasonry
    private var targetColumnWidth: CGFloat = 228
    private var topInset: CGFloat = 76
    private var bottomInset: CGFloat = 96
    private var activeQuickLookID: UUID?
    private var isOverlayPresented: Bool = false
    private var isDarkMode: Bool = false
    private var reduceMotion: Bool = false
    private var callbacks = MasonryCallbacks()
    private var lastInteractiveZoomAt: CFAbsoluteTime = 0
    private var lastPublishedZoomWidth: CGFloat = 228
    private var lastAppliedJustifiedWidth: CGFloat = 214

    // Photos-style persistent exact-asset zoom anchor & live optical pinch state
    private struct ZoomAssetAnchor {
        let assetID: UUID
        let normU: CGFloat
        let normV: CGFloat
        var screenY: CGFloat
    }
    private var sessionZoomAnchor: ZoomAssetAnchor?
    private var lastZoomCursorWindowPoint: NSPoint?
    private var isProgrammaticZoomScroll: Bool = false
    private var isPinching: Bool = false
    private var pinchOpticalScale: CGFloat = 1.0
    private var pinchAnchorScreenPoint: CGPoint = .zero
    private var legacyPinchSettleWorkItem: DispatchWorkItem?
    private var scrollZoomAccumulator: CGFloat = 0
    private var lastScrollZoomStepAt: CFAbsoluteTime = 0
    private var pendingRevealRequest: MasonryRevealRequest?
    private var lastHandledRevealNonce: UUID?

    // Single-shot GPU-synchronized reflow during Sidebar / Inspector drawer animations
    private var lastSideChromeWidth: CGFloat?
    private var paneTransitionTargetWidth: CGFloat?
    private var paneTransitionWindowWidth: CGFloat?
    private var paneTransitionDeadline: CFAbsoluteTime = 0
    private var paneTransitionSettleWorkItem: DispatchWorkItem?
    private var isInPaneTransition: Bool {
        paneTransitionTargetWidth != nil && CFAbsoluteTimeGetCurrent() < paneTransitionDeadline
    }

    // O(1) pasteboard changeCount cache for zero-XPC `draggingUpdated`
    private var cachedDragChangeCount: Int = -1
    private var cachedDragIsInternal: Bool = false

    private let spacing: CGFloat = 12
    private let horizontalPadding: CGFloat = 20
    private let tileOverscan: CGFloat = 260
    private let prefetchLookahead: CGFloat = 640
    private let maxPrefetchBatch: Int = 12
    private let maxReusePoolSize: Int = 32

    private var layout: MasonryLayoutSnapshot = .empty
    private var lastLayoutWidth: CGFloat = 0
    private var activeTiles: [UUID: MasonryTileLayer] = [:]
    private var reusePool: [MasonryTileLayer] = []
    private var visibleFramesScratch: [MasonryItemFrame] = []
    private var neededIDsScratch: Set<UUID> = []
    private var recycleIDsScratch: [UUID] = []
    private var prefetchIDsScratch: [UUID] = []
    private var lastPrefetchIDs: [UUID] = []
    internal private(set) var layoutRecomputeCountForTesting: Int = 0

    internal var activeTileCountForTesting: Int { activeTiles.count }
    internal var reusePoolCountForTesting: Int { reusePool.count }
    internal var maxActiveTileSublayerCountForTesting: Int {
        activeTiles.values.map(\.sublayerCountForTesting).max() ?? 0
    }
    internal var pooledTilesHoldingImageCountForTesting: Int {
        reusePool.reduce(0) { $0 + ($1.hasImageContentsForTesting ? 1 : 0) }
    }
    internal var currentLayoutTotalHeightForTesting: CGFloat { layout.totalHeight }
    internal var isOverlayPresentedForTesting: Bool { isOverlayPresented }
    internal var isHoverPreviewActiveForTesting: Bool { hoverMediaPreview.isActiveForTesting }
    internal var isMarqueeHiddenForTesting: Bool { marqueeLayer.isHidden }
    internal var activeTileHasImageContentsForTesting: [UUID: Bool] {
        activeTiles.mapValues(\.hasImageContentsForTesting)
    }
    private let tilesContainerLayer = CALayer()
    private let hoverMediaPreview = HoverMediaPreviewLayerController()
    private let hoverOverlayLayer = MasonryHoverOverlayLayer()
    private let marqueeLayer = CALayer()

    private var hoveredAssetID: UUID?
    private var isLiveScrolling: Bool = false
    private var lastScrollY: CGFloat = 0
    private var scrollingDown: Bool = true
    private var lastClickedID: UUID?
    private var trackingAreaRef: NSTrackingArea?
    private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []
    private var marqueeAutoscrollTimer: Timer?
    private var lastMarqueeEvent: NSEvent?

    // Mouse / drag / marquee state
    private enum PointerMode {
        case none
        case pendingCard(asset: AssetRecord, frame: CGRect, startPoint: CGPoint, event: NSEvent)
        case marquee(startPoint: CGPoint, baseSelection: Set<UUID>)
    }
    private var pointerMode: PointerMode = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func makeBackingLayer() -> CALayer {
        let root = super.makeBackingLayer()
        root.actions = MasonryStaticLayerAssets.noImplicitActions
        return root
    }

    private func setupView() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = self.layer else { return }
        root.actions = MasonryStaticLayerAssets.noImplicitActions

        tilesContainerLayer.anchorPoint = .zero
        tilesContainerLayer.position = .zero
        tilesContainerLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        root.addSublayer(tilesContainerLayer)
        root.addSublayer(hoverMediaPreview.containerLayer)
        root.addSublayer(hoverOverlayLayer.layer)

        marqueeLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        marqueeLayer.cornerRadius = 4
        marqueeLayer.borderWidth = 1
        marqueeLayer.zPosition = 900
        marqueeLayer.isHidden = true
        root.addSublayer(marqueeLayer)

        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeLifecycleObservers()
        if let hostWindow = window {
            MasonryCardGeometryRegistry.shared.register(self)
            installLifecycleObservers(for: hostWindow)
            handleViewportFrameChanged()
        } else {
            releaseOffscreenResources()
        }
    }

    isolated deinit {
        stopMarqueeAutoscrollTimer()
        removeLifecycleObservers()
        MasonryCardGeometryRegistry.shared.unregister(self)
    }

    private func installLifecycleObservers(for hostWindow: NSWindow) {
        let nc = NotificationCenter.default
        lifecycleObservers.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: hostWindow,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspendHoverAndTransientInteractions()
            }
        })
        lifecycleObservers.append(nc.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: hostWindow,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let win = self.window else { return }
                if !win.occlusionState.contains(.visible) {
                    self.suspendHoverAndTransientInteractions()
                }
            }
        })
        lifecycleObservers.append(nc.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspendHoverAndTransientInteractions()
            }
        })
        lifecycleObservers.append(nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.suspendHoverAndTransientInteractions()
            }
        })
    }

    private func removeLifecycleObservers() {
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
        lifecycleObservers.removeAll()
    }

    private func stopMarqueeAutoscrollTimer() {
        marqueeAutoscrollTimer?.invalidate()
        marqueeAutoscrollTimer = nil
        lastMarqueeEvent = nil
    }

    private func suspendHoverAndTransientInteractions() {
        hoveredAssetID = nil
        hoverOverlayLayer.hide()
        hoverMediaPreview.stop()
        stopMarqueeAutoscrollTimer()
        if case .marquee = pointerMode {
            pointerMode = .none
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            marqueeLayer.isHidden = true
            CATransaction.commit()
        }
    }

    internal func releaseOffscreenResources() {
        MasonryCardGeometryRegistry.shared.unregister(self)
        removeLifecycleObservers()
        stopMarqueeAutoscrollTimer()
        pointerMode = .none
        hoveredAssetID = nil
        hoverMediaPreview.stop()
        hoverOverlayLayer.releaseContents()
        legacyPinchSettleWorkItem?.cancel()
        legacyPinchSettleWorkItem = nil
        paneTransitionSettleWorkItem?.cancel()
        paneTransitionSettleWorkItem = nil
        paneTransitionTargetWidth = nil
        paneTransitionWindowWidth = nil
        lastPrefetchIDs.removeAll()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marqueeLayer.isHidden = true
        for tile in activeTiles.values {
            tile.prepareForReuse()
            tile.layer.removeFromSuperlayer()
        }
        activeTiles.removeAll()
        for tile in reusePool {
            tile.prepareForReuse()
        }
        reusePool.removeAll()
        CATransaction.commit()
    }

    func visibleCardRectInWindow(for assetID: UUID) -> CGRect? {
        guard let window, let contentView = window.contentView else { return nil }
        guard let index = assetIndexByID[assetID], index < layout.items.count else { return nil }
        let cardRect = layout.items[index].rect
        guard cardRect.intersects(visibleRect) else { return nil }
        let rectInContent = convert(cardRect, to: contentView)
        let contentHeight = contentView.bounds.height
        guard contentHeight > 0 else { return nil }
        let topLeftY = contentView.isFlipped ? rectInContent.minY : (contentHeight - rectInContent.maxY)
        return CGRect(
            x: rectInContent.minX,
            y: topLeftY,
            width: rectInContent.width,
            height: rectInContent.height
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncVisibleTiles(forceReconfigure: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let effectiveDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if effectiveDark != isDarkMode {
            isDarkMode = effectiveDark
            syncVisibleTiles(forceReconfigure: true)
        }
    }

    private var currentScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    func applyState(
        assets: [AssetRecord],
        signature: MasonryAssetsSignature,
        folders: [FolderRecord],
        loaderInvalidationVersion: Int,
        selectedIDs: Set<UUID>,
        cutIDs: Set<UUID>,
        layoutMode: GalleryLayoutMode,
        targetColumnWidth: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        sideChromeWidth: CGFloat?,
        isLivePaneResizing: Bool = false,
        activeQuickLookID: UUID?,
        isOverlayPresented: Bool = false,
        revealRequest: MasonryRevealRequest?,
        isDarkMode: Bool,
        reduceMotion: Bool,
        callbacks: MasonryCallbacks
    ) {
        let hadAssetsBefore = !self.assets.isEmpty
        let assetsChanged = (self.assetsSignature != signature)
        let layoutModeChanged = (self.layoutMode != layoutMode)
        let columnWidthChanged = abs(self.targetColumnWidth - targetColumnWidth) >= 0.5
        let topInsetChanged = abs(self.topInset - topInset) >= 0.5
        let oldBottomInset = self.bottomInset
        let bottomInsetChanged = abs(oldBottomInset - bottomInset) >= 0.5
        let insetsChanged = topInsetChanged || bottomInsetChanged
        let previousSideChrome = self.lastSideChromeWidth
        let sideChromeChanged: Bool = {
            guard let prev = previousSideChrome, let next = sideChromeWidth else { return false }
            return abs(prev - next) >= 1
        }()
        let previousInvalidationVersion = self.loaderInvalidationVersion
        let invalidationChanged = (previousInvalidationVersion != loaderInvalidationVersion)
        let appearanceChanged = (self.isDarkMode != isDarkMode)
        let selectionChanged = (self.selectedAssetIDs != selectedIDs)
        let overlayChanged = (self.isOverlayPresented != isOverlayPresented)
        let visualFlagsChanged = selectionChanged
            || (self.cutAssetIDs != cutIDs)
            || (self.activeQuickLookID != activeQuickLookID)

        if assetsChanged || selectionChanged {
            sessionZoomAnchor = nil
            lastZoomCursorWindowPoint = nil
        }

        let targetedInvalidatedIDs: Set<UUID>?
        let needsFullImageReload: Bool
        if invalidationChanged && previousInvalidationVersion != -1 {
            if let targeted = loader?.invalidatedAssetIDs(since: previousInvalidationVersion) {
                targetedInvalidatedIDs = targeted.isEmpty ? nil : targeted
                needsFullImageReload = false
                if !targeted.isEmpty {
                    lastPrefetchIDs.removeAll { targeted.contains($0) }
                }
            } else {
                targetedInvalidatedIDs = nil
                needsFullImageReload = true
                MasonryStaticLayerAssets.clearTransientCaches()
                lastPrefetchIDs.removeAll()
            }
        } else {
            targetedInvalidatedIDs = nil
            needsFullImageReload = false
        }

        self.assets = assets
        self.assetsSignature = signature
        self.folders = folders
        self.loaderInvalidationVersion = loaderInvalidationVersion
        self.selectedAssetIDs = selectedIDs
        self.cutAssetIDs = cutIDs
        self.layoutMode = layoutMode
        self.targetColumnWidth = targetColumnWidth
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.lastSideChromeWidth = sideChromeWidth
        self.activeQuickLookID = activeQuickLookID
        self.isOverlayPresented = isOverlayPresented
        if activeQuickLookID != nil || isOverlayPresented {
            suspendHoverAndTransientInteractions()
        } else if overlayChanged {
            refreshHoverForCurrentMouseLocation()
        }
        self.isDarkMode = isDarkMode
        self.reduceMotion = reduceMotion
        self.callbacks = callbacks

        if assetsChanged {
            var map: [UUID: Int] = [:]
            map.reserveCapacity(assets.count)
            for (idx, item) in assets.enumerated() {
                map[item.id] = idx
            }
            self.assetIndexByID = map
            lastPrefetchIDs.removeAll()
        }

        let isSelfZoomEcho = !assetsChanged && !layoutModeChanged && !insetsChanged && !sideChromeChanged && columnWidthChanged
            && abs(targetColumnWidth - lastPublishedZoomWidth) < 1.0
            && (CFAbsoluteTimeGetCurrent() - lastInteractiveZoomAt) < 0.45

        if let revealRequest, revealRequest.nonce != lastHandledRevealNonce {
            pendingRevealRequest = revealRequest
        }

        // During live pointer-driven sidebar resizing or live window resize, cancel any active
        // fixed-target drawer lock and let `handleViewportFrameChanged()` track the live edge smoothly.
        if isLivePaneResizing || window?.inLiveResize == true {
            paneTransitionSettleWorkItem?.cancel()
            paneTransitionSettleWorkItem = nil
            paneTransitionTargetWidth = nil
            paneTransitionWindowWidth = nil
        }

        // Single-shot GPU-synchronized reflow when Sidebar collapses/expands or Inspector toggles:
        // computes the exact post-drawer layout ONCE at t=0 and glides cards in lockstep with
        // `drawerEase` (0.30s) instead of thrashing layout 40+ times during the SwiftUI HStack animation.
        if sideChromeChanged,
           !isLivePaneResizing,
           window?.inLiveResize != true,
           let prevChrome = previousSideChrome,
           let nextChrome = sideChromeWidth,
           let clipView = enclosingScrollView?.contentView,
           clipView.bounds.width > 120 {
            let liveWindowWidth = window?.frame.width
            let baseWidth: CGFloat = {
                if isInPaneTransition, let prevTarget = paneTransitionTargetWidth {
                    let windowDelta: CGFloat
                    if let curWin = liveWindowWidth, let prevWin = paneTransitionWindowWidth {
                        windowDelta = curWin - prevWin
                    } else {
                        windowDelta = 0
                    }
                    return prevTarget + windowDelta
                }
                return floor(clipView.bounds.width)
            }()
            let targetWidth = MasonryLayoutEngine.paneTransitionTargetWidth(
                currentViewportWidth: baseWidth,
                previousSideChromeWidth: prevChrome,
                newSideChromeWidth: nextChrome
            )
            let drawerDuration: CFTimeInterval = reduceMotion ? 0.15 : 0.30
            paneTransitionTargetWidth = targetWidth
            paneTransitionWindowWidth = liveWindowWidth
            paneTransitionDeadline = CFAbsoluteTimeGetCurrent() + drawerDuration + 0.08
            schedulePaneTransitionSettle(after: drawerDuration + 0.09)

            if !assetsChanged && !layoutModeChanged && !insetsChanged && !columnWidthChanged && layout.items.count == assets.count {
                sessionZoomAnchor = nil
                lastZoomCursorWindowPoint = nil
                cancelOpticalTransformImmediate()
                hoveredAssetID = nil
                hoverOverlayLayer.hide()
                hoverMediaPreview.stop()
                _ = recomputeLayoutAnchored(
                    anchorDocPoint: nil,
                    forceCursorLookup: false,
                    animate: !reduceMotion && hadAssetsBefore,
                    animationDuration: drawerDuration,
                    timingFunction: CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1),
                    forceReconfigureExisting: needsFullImageReload || appearanceChanged,
                    forceReloadImages: needsFullImageReload,
                    targetedReloadIDs: targetedInvalidatedIDs,
                    isPaneTransition: true
                )
                sessionZoomAnchor = nil
                lastZoomCursorWindowPoint = nil
                if visualFlagsChanged && !(needsFullImageReload || appearanceChanged) {
                    updateVisibleTileStatesOnly()
                }
                fulfillPendingRevealIfPossible()
                return
            }
        }

        if isSelfZoomEcho {
            if needsFullImageReload || appearanceChanged {
                syncVisibleTiles(forceReconfigure: true, forceReloadImages: needsFullImageReload, targetedReloadIDs: targetedInvalidatedIDs)
            } else {
                if let targetedInvalidatedIDs {
                    reloadTargetedActiveTiles(targetedInvalidatedIDs)
                }
                if visualFlagsChanged {
                    updateVisibleTileStatesOnly()
                }
            }
            fulfillPendingRevealIfPossible()
            return
        }

        // Fast O(1) path when ONLY `bottomInset` changes (e.g., multi-select bottom action bar
        // toggling between 44pt and 104pt on every 1 <-> 2 selection change): avoids O(N) re-layout
        // and redundant tile reconfiguration.
        if bottomInsetChanged
            && !assetsChanged
            && !layoutModeChanged
            && !topInsetChanged
            && !columnWidthChanged
            && layout.items.count == assets.count
            && layout.totalHeight > 360.5 {
            layout = layout.withAdjustedBottomInset(oldBottomInset: oldBottomInset, newBottomInset: bottomInset)
            let clipHeight = enclosingScrollView?.contentView.bounds.height ?? bounds.height
            updateDocumentHeight(clipHeight: clipHeight)
            if needsFullImageReload || appearanceChanged {
                syncVisibleTiles(forceReconfigure: true, forceReloadImages: needsFullImageReload, targetedReloadIDs: targetedInvalidatedIDs)
            } else {
                if let targetedInvalidatedIDs {
                    reloadTargetedActiveTiles(targetedInvalidatedIDs)
                }
                if visualFlagsChanged {
                    updateVisibleTileStatesOnly()
                }
            }
            fulfillPendingRevealIfPossible()
            return
        }

        if assetsChanged || layoutModeChanged || insetsChanged || layout.items.count != assets.count {
            let shouldAnimate = !reduceMotion && hadAssetsBefore && (layoutModeChanged || assetsChanged)
            if layoutModeChanged && hadAssetsBefore {
                _ = recomputeLayoutAnchored(
                    anchorDocPoint: nil,
                    forceCursorLookup: false,
                    animate: shouldAnimate,
                    animationDuration: 0.28,
                    forceReloadImages: needsFullImageReload,
                    targetedReloadIDs: targetedInvalidatedIDs
                )
            } else {
                recomputeLayout(
                    animate: shouldAnimate,
                    animateNewTiles: shouldAnimate && assetsChanged,
                    forceReloadImages: needsFullImageReload,
                    targetedReloadIDs: targetedInvalidatedIDs
                )
            }
        } else if columnWidthChanged {
            // Only reflow when the discrete column count (Vertical) or quantized row-height stop (Justified)
            // actually changes — eliminates 120Hz slider-drag twitching and boundary oscillation.
            let width = activeContainerWidth()
            let densityChanged: Bool = switch layoutMode {
            case .verticalMasonry, .galleryFilmstrip, .ringGallery:
                MasonryLayoutEngine.verticalColumnCount(
                    containerWidth: width,
                    targetColumnWidth: targetColumnWidth,
                    spacing: spacing,
                    horizontalPadding: horizontalPadding
                ) != layout.columnCount
            case .horizontalJustified:
                abs(MasonryLayoutEngine.snappedJustifiedTargetWidth(targetColumnWidth) - lastAppliedJustifiedWidth) >= 0.5
            }
            if densityChanged {
                cancelOpticalTransformImmediate()
                _ = recomputeLayoutAnchored(
                    anchorDocPoint: nil,
                    forceCursorLookup: false,
                    animate: !reduceMotion && hadAssetsBefore,
                    animationDuration: 0.28,
                    forceReloadImages: needsFullImageReload,
                    targetedReloadIDs: targetedInvalidatedIDs
                )
            } else if needsFullImageReload || appearanceChanged {
                syncVisibleTiles(forceReconfigure: true, forceReloadImages: needsFullImageReload, targetedReloadIDs: targetedInvalidatedIDs)
            } else {
                if let targetedInvalidatedIDs {
                    reloadTargetedActiveTiles(targetedInvalidatedIDs)
                }
                if visualFlagsChanged {
                    updateVisibleTileStatesOnly()
                }
            }
        } else if needsFullImageReload || appearanceChanged {
            syncVisibleTiles(forceReconfigure: true, forceReloadImages: needsFullImageReload, targetedReloadIDs: targetedInvalidatedIDs)
        } else {
            if let targetedInvalidatedIDs {
                reloadTargetedActiveTiles(targetedInvalidatedIDs)
            }
            if visualFlagsChanged {
                updateVisibleTileStatesOnly()
            }
        }

        fulfillPendingRevealIfPossible()
    }

    private func reloadTargetedActiveTiles(_ invalidatedIDs: Set<UUID>) {
        guard !invalidatedIDs.isEmpty, !activeTiles.isEmpty else { return }
        let scale = currentScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in invalidatedIDs {
            guard let tile = activeTiles[id],
                  let idx = assetIndexByID[id],
                  idx < assets.count else { continue }
            let asset = assets[idx]
            tile.configure(
                asset: asset,
                frame: tile.frame,
                isSelected: selectedAssetIDs.contains(id),
                isCut: cutAssetIDs.contains(id),
                isHiddenForHero: activeQuickLookID == id,
                isDark: isDarkMode,
                scale: scale,
                loader: loader,
                forceReloadImage: true,
                isLiveScrolling: isLiveScrolling
            )
        }
        CATransaction.commit()
    }

    private func schedulePaneTransitionSettle(after delay: TimeInterval) {
        paneTransitionSettleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.paneTransitionSettleWorkItem = nil
                self.paneTransitionTargetWidth = nil
                self.paneTransitionWindowWidth = nil
                guard let clipView = self.enclosingScrollView?.contentView else { return }
                let actualWidth = floor(clipView.bounds.width)
                if actualWidth > 120, abs(actualWidth - self.lastLayoutWidth) >= 2 {
                    if clipView.bounds.origin.y > 4 {
                        self.sessionZoomAnchor = nil
                        _ = self.recomputeLayoutAnchored(
                            anchorDocPoint: nil,
                            forceCursorLookup: false,
                            animate: false,
                            forceReconfigureExisting: false
                        )
                        self.sessionZoomAnchor = nil
                    } else {
                        self.recomputeLayout(animate: false, reconfigureExisting: false)
                    }
                } else {
                    self.updateDocumentHeight(clipHeight: clipView.bounds.height)
                    self.syncVisibleTiles()
                }
                self.refreshHoverForCurrentMouseLocation()
            }
        }
        paneTransitionSettleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fulfillPendingRevealIfPossible() {
        guard let request = pendingRevealRequest,
              request.nonce != lastHandledRevealNonce,
              let clipView = enclosingScrollView?.contentView,
              clipView.bounds.height > 40,
              lastLayoutWidth > 120,
              let item = layoutItem(for: request.assetID) else {
            return
        }

        lastHandledRevealNonce = request.nonce
        pendingRevealRequest = nil
        sessionZoomAnchor = nil
        cancelOpticalTransformImmediate()

        let targetScrollY = MasonryLayoutEngine.revealScrollY(
            for: item.rect,
            topInset: topInset,
            bottomInset: bottomInset,
            totalHeight: layout.totalHeight,
            viewportHeight: clipView.bounds.height
        )

        isProgrammaticZoomScroll = true
        clipView.scroll(to: NSPoint(x: 0, y: targetScrollY))
        enclosingScrollView?.reflectScrolledClipView(clipView)
        lastScrollY = targetScrollY
        isProgrammaticZoomScroll = false

        syncVisibleTiles()

        if let tile = activeTiles[request.assetID] {
            tile.animateRevealSpotlight(reduceMotion: reduceMotion)
        }
        window?.makeFirstResponder(self)
    }

    // MARK: - macOS Photos-Style Optical Pinch & ⌘+Scroll Gallery Zoom

    private func activeContainerWidth() -> CGFloat {
        if isInPaneTransition, let target = paneTransitionTargetWidth {
            return max(240, target)
        }
        let clipBounds = enclosingScrollView?.contentView.bounds ?? bounds
        return max(240, floor(clipBounds.width > 120 ? clipBounds.width : max(lastLayoutWidth, 960)))
    }

    private func effectiveLayoutTargetWidth(for rawWidth: CGFloat, mode: GalleryLayoutMode) -> CGFloat {
        mode == .horizontalJustified
            ? MasonryLayoutEngine.snappedJustifiedTargetWidth(rawWidth)
            : rawWidth
    }

    private func opticalTransform(scale: CGFloat, anchorDoc: CGPoint) -> CATransform3D {
        guard abs(scale - 1.0) > 0.0005 else { return CATransform3DIdentity }
        let affine = CGAffineTransform(
            a: scale, b: 0,
            c: 0, d: scale,
            tx: anchorDoc.x * (1.0 - scale),
            ty: anchorDoc.y * (1.0 - scale)
        )
        return CATransform3DMakeAffineTransform(affine)
    }

    private func applyOpticalTransformImmediate(scale: CGFloat, anchorScreen: CGPoint) {
        let scrollY = enclosingScrollView?.contentView.bounds.origin.y ?? visibleRect.minY
        let anchorDoc = CGPoint(x: anchorScreen.x, y: scrollY + anchorScreen.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tilesContainerLayer.removeAnimation(forKey: "charkle.pinchSettle")
        tilesContainerLayer.transform = opticalTransform(scale: scale, anchorDoc: anchorDoc)
        CATransaction.commit()
    }

    private func cancelOpticalTransformImmediate() {
        legacyPinchSettleWorkItem?.cancel()
        legacyPinchSettleWorkItem = nil
        isPinching = false
        pinchOpticalScale = 1.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tilesContainerLayer.removeAnimation(forKey: "charkle.pinchSettle")
        tilesContainerLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func settleOpticalTransformToIdentity() {
        legacyPinchSettleWorkItem?.cancel()
        legacyPinchSettleWorkItem = nil
        let fromTransform = tilesContainerLayer.presentation()?.transform ?? tilesContainerLayer.transform
        isPinching = false
        pinchOpticalScale = 1.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tilesContainerLayer.removeAnimation(forKey: "charkle.pinchSettle")
        tilesContainerLayer.transform = CATransform3DIdentity
        CATransaction.commit()

        if !reduceMotion && !CATransform3DEqualToTransform(fromTransform, CATransform3DIdentity) {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: fromTransform)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.mass = 1.0
            spring.stiffness = 320
            spring.damping = 36 // Critically damped, zero bounce
            spring.duration = min(0.32, spring.settlingDuration)
            tilesContainerLayer.add(spring, forKey: "charkle.pinchSettle")
        }
        refreshHoverForCurrentMouseLocation()
    }

    private func layoutItem(for assetID: UUID) -> MasonryItemFrame? {
        guard let idx = assetIndexByID[assetID],
              idx < layout.items.count,
              layout.items[idx].id == assetID else {
            return nil
        }
        return layout.items[idx]
    }

    /// Resolves and persists ONE exact asset card as the zoom anchor across the entire zoom session
    /// (pinch steps, slider drags, +/- clicks, or ⌘+scroll bursts) until the user scrolls manually or changes selection.
    private func resolveSessionZoomAnchor(
        near docPoint: CGPoint?,
        forceCursorLookup: Bool,
        oldScrollY: CGFloat,
        oldOpticalScale: CGFloat = 1.0,
        oldOpticalAnchorScreen: CGPoint = .zero
    ) -> (anchor: ZoomAssetAnchor, item: MasonryItemFrame)? {
        func makeAnchor(for item: MasonryItemFrame, docHitPoint: CGPoint?) -> ZoomAssetAnchor {
            let u: CGFloat
            let v: CGFloat
            if let pt = docHitPoint, item.rect.width > 1, item.rect.height > 1 {
                u = max(0.05, min(0.95, (pt.x - item.rect.minX) / item.rect.width))
                v = max(0.05, min(0.95, (pt.y - item.rect.minY) / item.rect.height))
            } else {
                u = 0.5
                v = 0.5
            }
            let rawY = item.rect.minY + v * item.rect.height - oldScrollY
            let screenY = oldOpticalAnchorScreen.y + (rawY - oldOpticalAnchorScreen.y) * oldOpticalScale
            return ZoomAssetAnchor(assetID: item.id, normU: u, normV: v, screenY: screenY)
        }

        // 1. Pointer-driven lookup (pinch .began or ⌘+scroll over a specific card): lock to exact card under cursor
        if forceCursorLookup, let docPoint {
            if let hit = hitTestCard(at: docPoint), let item = layoutItem(for: hit.asset.id) {
                if let existing = sessionZoomAnchor, existing.assetID == item.id {
                    return (existing, item)
                }
                let anchor = makeAnchor(for: item, docHitPoint: docPoint)
                sessionZoomAnchor = anchor
                return (anchor, item)
            }
        }

        // 2. Reuse existing session anchor so consecutive steps stay locked on the EXACT same asset
        if let existing = sessionZoomAnchor, let item = layoutItem(for: existing.assetID) {
            return (existing, item)
        }

        // 3. Fallback priority: visible selected asset > card nearest cursor > card nearest viewport center
        let vis = visibleRect
        if !selectedAssetIDs.isEmpty {
            let visibleSelected = selectedAssetIDs.compactMap { id -> MasonryItemFrame? in
                guard let item = layoutItem(for: id), item.rect.intersects(vis) else { return nil }
                return item
            }
            if let bestSel = visibleSelected.min(by: {
                hypot($0.rect.midX - vis.midX, $0.rect.midY - vis.midY) < hypot($1.rect.midX - vis.midX, $1.rect.midY - vis.midY)
            }) {
                let anchor = makeAnchor(for: bestSel, docHitPoint: nil)
                sessionZoomAnchor = anchor
                return (anchor, bestSel)
            }
        }

        if let docPoint {
            let candidates = layout.visibleItems(minY: max(0, vis.minY - 60), maxY: vis.maxY + 60)
            if let nearest = candidates.min(by: {
                hypot($0.rect.midX - docPoint.x, $0.rect.midY - docPoint.y) < hypot($1.rect.midX - docPoint.x, $1.rect.midY - docPoint.y)
            }) {
                let anchor = makeAnchor(for: nearest, docHitPoint: nil)
                sessionZoomAnchor = anchor
                return (anchor, nearest)
            }
        }

        let visCandidates = layout.visibleItems(minY: vis.minY, maxY: vis.maxY)
        if let centerItem = visCandidates.min(by: {
            hypot($0.rect.midX - vis.midX, $0.rect.midY - vis.midY) < hypot($1.rect.midX - vis.midX, $1.rect.midY - vis.midY)
        }) {
            let anchor = makeAnchor(for: centerItem, docHitPoint: nil)
            sessionZoomAnchor = anchor
            return (anchor, centerItem)
        }
        return nil
    }

    /// Continuous trackpad two-finger pinch: 120fps GPU optical scaling pivoted on the exact anchor asset
    /// with seamless optical-rebased handoff across column/density steps and critically damped settle on release.
    func handleMagnifyGesture(_ event: NSEvent) {
        guard !assets.isEmpty else { return }

        let phase = event.phase
        let scrollY = enclosingScrollView?.contentView.bounds.origin.y ?? visibleRect.minY
        let cursorInDoc = convert(event.locationInWindow, from: nil)
        let cursorScreen = CGPoint(
            x: max(0, min(visibleRect.width, cursorInDoc.x)),
            y: max(0, min(visibleRect.height, cursorInDoc.y - scrollY))
        )

        if phase.contains(.ended) || phase.contains(.cancelled) {
            settleOpticalTransformToIdentity()
            return
        }

        if phase.contains(.began) || !isPinching {
            isPinching = true
            // Fresh pinch gesture re-measures exact live (u, v, screenY) on the card under cursor
            sessionZoomAnchor = nil
            lastZoomCursorWindowPoint = nil
            // Pick up live visual scale & transform if interrupting an in-flight settle spring
            let livePresentation = tilesContainerLayer.presentation()?.transform ?? tilesContainerLayer.transform
            let liveScale = max(0.84, min(1.18, livePresentation.m11))
            let interruptingSettle = abs(liveScale - 1.0) > 0.005
            pinchOpticalScale = liveScale
            tilesContainerLayer.removeAnimation(forKey: "charkle.pinchSettle")

            let unscaledLookupDoc: CGPoint
            let lookupOpticalAnchor: CGPoint
            if interruptingSettle {
                let affine = CATransform3DGetAffineTransform(livePresentation)
                unscaledLookupDoc = cursorInDoc.applying(affine.inverted())
                lookupOpticalAnchor = pinchAnchorScreenPoint
            } else {
                unscaledLookupDoc = cursorInDoc
                lookupOpticalAnchor = cursorScreen
            }

            // Lock to the EXACT card under the cursor (or visible selected / center card) and pivot optical zoom on it
            if let resolved = resolveSessionZoomAnchor(
                near: unscaledLookupDoc,
                forceCursorLookup: true,
                oldScrollY: scrollY,
                oldOpticalScale: interruptingSettle ? liveScale : 1.0,
                oldOpticalAnchorScreen: lookupOpticalAnchor
            ) {
                let item = resolved.item
                let pivotX = item.rect.minX + resolved.anchor.normU * item.rect.width
                pinchAnchorScreenPoint = CGPoint(x: pivotX, y: resolved.anchor.screenY)
            } else {
                pinchAnchorScreenPoint = cursorScreen
            }
            if interruptingSettle {
                applyOpticalTransformImmediate(scale: liveScale, anchorScreen: pinchAnchorScreenPoint)
            }

            hoveredAssetID = nil
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
            for tile in activeTiles.values {
                tile.stripLayoutAnimations()
            }
        }

        let mag = event.magnification
        guard abs(mag) > 0.0002 || phase.contains(.began) else { return }

        let width = activeContainerWidth()
        let rawNext = pinchOpticalScale * max(0.75, min(1.35, 1.0 + mag * 1.08))

        // Determine step ratios & thresholds with generous 56% hysteresis so finger wiggle never thrashes
        var steppedTargetWidth: CGFloat? = nil
        var stepRatio: CGFloat = 1.0
        var atZoomInLimit = false
        var atZoomOutLimit = false

        switch layoutMode {
        case .verticalMasonry, .galleryFilmstrip, .ringGallery:
            let cols = layout.columnCount
            let minCols = MasonryLayoutEngine.minReachableVerticalColumns(
                containerWidth: width,
                spacing: spacing,
                horizontalPadding: horizontalPadding
            )
            let maxCols = MasonryLayoutEngine.maxReachableVerticalColumns(
                containerWidth: width,
                spacing: spacing,
                horizontalPadding: horizontalPadding
            )
            let curW = MasonryLayoutEngine.verticalColumnWidth(
                containerWidth: width,
                columnCount: cols,
                spacing: spacing,
                horizontalPadding: horizontalPadding
            )
            atZoomInLimit = (cols <= minCols)
            atZoomOutLimit = (cols >= maxCols)

            if rawNext > 1.0, !atZoomInLimit {
                let nextW = MasonryLayoutEngine.verticalColumnWidth(
                    containerWidth: width,
                    columnCount: cols - 1,
                    spacing: spacing,
                    horizontalPadding: horizontalPadding
                )
                let ratio = nextW / max(1, curW)
                let threshold = 1.0 + (ratio - 1.0) * 0.56
                if rawNext >= threshold {
                    steppedTargetWidth = MasonryLayoutEngine.canonicalTargetWidth(
                        forVerticalColumns: cols - 1,
                        containerWidth: width,
                        spacing: spacing,
                        horizontalPadding: horizontalPadding
                    )
                    stepRatio = ratio
                }
            } else if rawNext < 1.0, !atZoomOutLimit {
                let nextW = MasonryLayoutEngine.verticalColumnWidth(
                    containerWidth: width,
                    columnCount: cols + 1,
                    spacing: spacing,
                    horizontalPadding: horizontalPadding
                )
                let ratio = nextW / max(1, curW)
                let threshold = 1.0 - (1.0 - ratio) * 0.56
                if rawNext <= threshold {
                    steppedTargetWidth = MasonryLayoutEngine.canonicalTargetWidth(
                        forVerticalColumns: cols + 1,
                        containerWidth: width,
                        spacing: spacing,
                        horizontalPadding: horizontalPadding
                    )
                    stepRatio = ratio
                }
            }

        case .horizontalJustified:
            let stops = MasonryLayoutEngine.justifiedZoomStops
            let curStop = MasonryLayoutEngine.snappedJustifiedTargetWidth(targetColumnWidth)
            let idx = stops.firstIndex(of: curStop) ?? 0
            atZoomInLimit = (idx >= stops.count - 1)
            atZoomOutLimit = (idx <= 0)

            if rawNext > 1.0, !atZoomInLimit {
                let nextStop = stops[idx + 1]
                let ratio = nextStop / max(1, curStop)
                let threshold = 1.0 + (ratio - 1.0) * 0.56
                if rawNext >= threshold {
                    steppedTargetWidth = nextStop
                    stepRatio = ratio
                }
            } else if rawNext < 1.0, !atZoomOutLimit {
                let nextStop = stops[idx - 1]
                let ratio = nextStop / max(1, curStop)
                let threshold = 1.0 - (1.0 - ratio) * 0.56
                if rawNext <= threshold {
                    steppedTargetWidth = nextStop
                    stepRatio = ratio
                }
            }
        }

        if let nextTargetWidth = steppedTargetWidth {
            let oldOptical = pinchOpticalScale
            let oldPivot = pinchAnchorScreenPoint
            let rebasedOptical = max(0.84, min(1.18, rawNext / max(0.4, stepRatio)))
            lastInteractiveZoomAt = CFAbsoluteTimeGetCurrent()
            lastPublishedZoomWidth = nextTargetWidth
            targetColumnWidth = nextTargetWidth
            pinchOpticalScale = rebasedOptical

            let updatedPivot = recomputeLayoutAnchored(
                anchorDocPoint: cursorInDoc,
                forceCursorLookup: false,
                animate: !reduceMotion,
                animationDuration: 0.28,
                oldOpticalScale: oldOptical,
                newOpticalScale: rebasedOptical,
                oldOpticalAnchorScreen: oldPivot
            )
            if let updatedPivot {
                pinchAnchorScreenPoint = updatedPivot
            }
            callbacks.onZoomColumnWidth?(nextTargetWidth)
        } else {
            // Pure GPU 120fps optical scaling between density stops (with soft Photos-style rubber-band at limits)
            let dampedScale: CGFloat
            if rawNext > 1.0 && atZoomInLimit {
                dampedScale = 1.0 + CGFloat(tanh(Double(rawNext - 1.0) * 3.0)) * 0.08
            } else if rawNext < 1.0 && atZoomOutLimit {
                dampedScale = 1.0 - CGFloat(tanh(Double(1.0 - rawNext) * 3.0)) * 0.08
            } else {
                dampedScale = max(0.76, min(1.36, rawNext))
            }
            pinchOpticalScale = dampedScale
            applyOpticalTransformImmediate(scale: dampedScale, anchorScreen: pinchAnchorScreenPoint)
        }

        // Fallback settle for synthetic/legacy magnify events that omit `.ended` phase
        if phase.isEmpty {
            legacyPinchSettleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.settleOpticalTransformToIdentity()
            }
            legacyPinchSettleWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }
    }

    /// Cleanly steps density on ⌘+scroll wheel (mouse wheel or trackpad) with exact-asset anchor locking
    /// and cooldown hysteresis so rapid wheel notches glide smoothly instead of thrashing.
    func handleCommandScrollZoom(
        delta: CGFloat,
        isDiscreteWheel: Bool,
        anchorDocPoint: NSPoint,
        cursorWindowPoint: NSPoint? = nil
    ) {
        guard !assets.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if isDiscreteWheel {
            guard (now - lastScrollZoomStepAt) >= 0.12 else { return }
            let direction = delta > 0 ? 1 : -1
            commitSteppedZoom(direction: direction, anchorDocPoint: anchorDocPoint, cursorWindowPoint: cursorWindowPoint)
            lastScrollZoomStepAt = now
            scrollZoomAccumulator = 0
            return
        }

        // Reset accumulator if direction reversed
        if (scrollZoomAccumulator > 0 && delta < 0) || (scrollZoomAccumulator < 0 && delta > 0) {
            scrollZoomAccumulator = 0
        }
        scrollZoomAccumulator += delta
        guard abs(scrollZoomAccumulator) >= 0.85, (now - lastScrollZoomStepAt) >= 0.15 else { return }

        let direction = scrollZoomAccumulator > 0 ? 1 : -1
        scrollZoomAccumulator = 0
        lastScrollZoomStepAt = now
        commitSteppedZoom(direction: direction, anchorDocPoint: anchorDocPoint, cursorWindowPoint: cursorWindowPoint)
    }

    private func commitSteppedZoom(direction: Int, anchorDocPoint: NSPoint, cursorWindowPoint: NSPoint?) {
        cancelOpticalTransformImmediate()
        let width = activeContainerWidth()
        let nextWidth = MasonryLayoutEngine.steppedColumnWidth(
            currentWidth: targetColumnWidth,
            direction: direction,
            layoutMode: layoutMode,
            containerWidth: width,
            spacing: spacing,
            horizontalPadding: horizontalPadding
        )
        guard abs(nextWidth - targetColumnWidth) >= 0.5 else { return }

        // Reuse the existing exact-asset zoom anchor across consecutive ⌘+scroll notches while
        // the pointer stays stationary (otherwise a reflowed card shifting columns causes anchor jumps).
        let cursorMoved: Bool = {
            guard let cur = cursorWindowPoint, let prev = lastZoomCursorWindowPoint else {
                return sessionZoomAnchor == nil
            }
            return hypot(cur.x - prev.x, cur.y - prev.y) > 8.0
        }()
        let shouldLookupCursor = (sessionZoomAnchor == nil) || cursorMoved
        if let cursorWindowPoint {
            lastZoomCursorWindowPoint = cursorWindowPoint
        }

        lastInteractiveZoomAt = CFAbsoluteTimeGetCurrent()
        lastPublishedZoomWidth = nextWidth
        targetColumnWidth = nextWidth

        _ = recomputeLayoutAnchored(
            anchorDocPoint: anchorDocPoint,
            forceCursorLookup: shouldLookupCursor,
            animate: !reduceMotion,
            animationDuration: 0.28
        )
        callbacks.onZoomColumnWidth?(nextWidth)
    }

    func handleViewportFrameChanged() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        if isInPaneTransition {
            if window?.inLiveResize == true {
                // User started actively resizing the window mid-drawer transition: cancel the
                // fixed-target drawer lock so live resize tracks the window edge immediately.
                paneTransitionSettleWorkItem?.cancel()
                paneTransitionSettleWorkItem = nil
                paneTransitionTargetWidth = nil
                paneTransitionWindowWidth = nil
            } else {
                // Suppress mid-animation per-frame reflows while the single-shot GPU transition is in flight.
                if clipView.bounds.height > frame.height + 1 {
                    updateDocumentHeight(clipHeight: clipView.bounds.height)
                }
                return
            }
        }
        paneTransitionTargetWidth = nil
        paneTransitionWindowWidth = nil
        let width = floor(clipView.bounds.width)
        guard width > 120 else { return }
        if abs(width - lastLayoutWidth) >= 1 {
            let oldCols = layout.columnCount
            let nextCols = MasonryLayoutEngine.verticalColumnCount(
                containerWidth: width,
                targetColumnWidth: targetColumnWidth,
                spacing: spacing,
                horizontalPadding: horizontalPadding
            )
            sessionZoomAnchor = nil
            cancelOpticalTransformImmediate()
            if clipView.bounds.origin.y > 4 && (layoutMode == .horizontalJustified || nextCols != oldCols) {
                _ = recomputeLayoutAnchored(
                    anchorDocPoint: nil,
                    forceCursorLookup: false,
                    animate: false,
                    forceReconfigureExisting: false
                )
                sessionZoomAnchor = nil
            } else {
                recomputeLayout(animate: false, reconfigureExisting: false)
            }
        } else {
            updateDocumentHeight(clipHeight: clipView.bounds.height)
            syncVisibleTiles()
        }
        fulfillPendingRevealIfPossible()
    }

    func handleScrollBoundsChanged() {
        let visY = visibleRect.minY
        if isProgrammaticZoomScroll {
            lastScrollY = visY
            return
        }
        if abs(visY - lastScrollY) > 1 {
            if !isPinching && abs(visY - lastScrollY) > 3 {
                sessionZoomAnchor = nil
                lastZoomCursorWindowPoint = nil
            }
            scrollingDown = visY >= lastScrollY
            lastScrollY = visY
        }
        syncVisibleTiles()
    }

    func setLiveScrolling(_ scrolling: Bool) {
        isLiveScrolling = scrolling
        if scrolling {
            sessionZoomAnchor = nil
            lastZoomCursorWindowPoint = nil
            cancelOpticalTransformImmediate()
            hoveredAssetID = nil
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
            for tile in activeTiles.values {
                tile.stripLayoutAnimations()
            }
        } else {
            // Re-sync after live scroll settles so any procedural cards deferred during 120Hz fling render cleanly.
            syncVisibleTiles()
            refreshHoverForCurrentMouseLocation()
        }
    }

    /// Recomputes layout while persistently locking ONE exact anchor asset card across consecutive zoom steps,
    /// keeping the anchor tile continuously animated on top (`zPosition = 40`), and compensating every tile's
    /// animation start rect for `ΔscrollY` + any optical pinch transform rebase.
    @discardableResult
    private func recomputeLayoutAnchored(
        anchorDocPoint: CGPoint?,
        forceCursorLookup: Bool,
        animate: Bool,
        animationDuration: CFTimeInterval = 0.28,
        timingFunction: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0),
        forceReconfigureExisting: Bool = true,
        forceReloadImages: Bool = false,
        targetedReloadIDs: Set<UUID>? = nil,
        isPaneTransition: Bool = false,
        oldOpticalScale: CGFloat = 1.0,
        newOpticalScale: CGFloat = 1.0,
        oldOpticalAnchorScreen: CGPoint = .zero
    ) -> CGPoint? {
        let clipView = enclosingScrollView?.contentView
        let clipBounds = clipView?.bounds ?? bounds
        let width = activeContainerWidth()
        lastLayoutWidth = width

        let oldScrollY = clipBounds.origin.y
        let resolvedAnchor = resolveSessionZoomAnchor(
            near: anchorDocPoint,
            forceCursorLookup: forceCursorLookup,
            oldScrollY: oldScrollY,
            oldOpticalScale: oldOpticalScale,
            oldOpticalAnchorScreen: oldOpticalAnchorScreen
        )

        // Snapshot EVERY currently mounted tile's exact visual screen rect BEFORE layout/scroll mutates
        var oldScreenRects: [UUID: CGRect] = [:]
        if animate && !isLiveScrolling {
            oldScreenRects.reserveCapacity(activeTiles.count)
            for (id, tile) in activeTiles {
                let pres = tile.layer.presentation()?.frame ?? tile.frame
                let cx = oldOpticalAnchorScreen.x + (pres.midX - oldOpticalAnchorScreen.x) * oldOpticalScale
                let cy = oldOpticalAnchorScreen.y + ((pres.midY - oldScrollY) - oldOpticalAnchorScreen.y) * oldOpticalScale
                let w = pres.width * oldOpticalScale
                let h = pres.height * oldOpticalScale
                oldScreenRects[id] = CGRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h)
            }
        }

        let effectiveWidth = effectiveLayoutTargetWidth(for: targetColumnWidth, mode: layoutMode)
        if layoutMode == .horizontalJustified {
            lastAppliedJustifiedWidth = effectiveWidth
        }

        layoutRecomputeCountForTesting &+= 1
        layout = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: layoutMode,
            containerWidth: width,
            targetColumnWidth: effectiveWidth,
            spacing: spacing,
            horizontalPadding: horizontalPadding,
            topInset: topInset,
            bottomInset: bottomInset
        )

        updateDocumentHeight(clipHeight: clipBounds.height)

        // Compute & apply exact anchor-locked scroll origin BEFORE mounting/animating visible tiles.
        // During Sidebar/Inspector drawer toggles, if the user is already at the very top of the library
        // (`oldScrollY <= 4`), keep `newScrollY = 0` so Row 1 never scrolls off-screen above the toolbar.
        var newScrollY = oldScrollY
        var newOpticalAnchorScreen = oldOpticalAnchorScreen
        let pinTopDuringPaneTransition = isPaneTransition && oldScrollY <= 4
        let anchorID = pinTopDuringPaneTransition ? nil : resolvedAnchor?.anchor.assetID

        if let clipView {
            let maxScrollY = max(0, layout.totalHeight - clipBounds.height)
            if let resolved = resolvedAnchor, let newAnchorItem = layoutItem(for: resolved.anchor.assetID) {
                let newAnchorRect = newAnchorItem.rect
                let targetScreenY = resolved.anchor.screenY
                if isPaneTransition {
                    newScrollY = MasonryLayoutEngine.paneTransitionScrollY(
                        oldScrollY: oldScrollY,
                        oldAnchorRect: resolved.item.rect,
                        newAnchorRect: newAnchorRect,
                        anchorNormV: resolved.anchor.normV,
                        anchorScreenY: targetScreenY,
                        topInset: topInset,
                        totalHeight: layout.totalHeight,
                        viewportHeight: clipBounds.height
                    )
                } else {
                    newScrollY = MasonryLayoutEngine.anchoredScrollY(
                        oldScrollY: oldScrollY,
                        oldAnchorRect: resolved.item.rect,
                        newAnchorRect: newAnchorRect,
                        anchorNormV: resolved.anchor.normV,
                        anchorScreenY: targetScreenY,
                        newOpticalScale: newOpticalScale,
                        opticalAnchorScreenY: targetScreenY,
                        topInset: topInset,
                        totalHeight: layout.totalHeight,
                        viewportHeight: clipBounds.height
                    )
                }

                // Track the exact anchor asset's post-handoff visual pivot so optical pinch follows THAT photo
                let newAnchorRawX = newAnchorRect.minX + resolved.anchor.normU * newAnchorRect.width
                let newAnchorRawY = newAnchorRect.minY + resolved.anchor.normV * newAnchorRect.height - newScrollY
                newOpticalAnchorScreen = CGPoint(x: newAnchorRawX, y: newAnchorRawY)
            } else {
                newScrollY = pinTopDuringPaneTransition ? 0 : max(0, min(maxScrollY, oldScrollY))
            }

            if abs(newScrollY - oldScrollY) >= 0.5 {
                isProgrammaticZoomScroll = true
                defer { isProgrammaticZoomScroll = false }
                clipView.scroll(to: NSPoint(x: 0, y: newScrollY))
                enclosingScrollView?.reflectScrolledClipView(clipView)
                lastScrollY = newScrollY
            }
        }

        // Apply rebased optical scale around the exact anchor asset's updated screen pivot
        if abs(newOpticalScale - 1.0) > 0.0005 || abs(oldOpticalScale - 1.0) > 0.0005 {
            applyOpticalTransformImmediate(scale: newOpticalScale, anchorScreen: newOpticalAnchorScreen)
        }

        // Map each tile's old visual screen rect into the new post-scroll, post-optical document space
        var compensatedFromRects: [UUID: CGRect] = [:]
        if animate && !isLiveScrolling && !oldScreenRects.isEmpty {
            compensatedFromRects.reserveCapacity(oldScreenRects.count)
            for (id, screenRect) in oldScreenRects {
                compensatedFromRects[id] = MasonryLayoutEngine.compensatedFromRect(
                    oldScreenRect: screenRect,
                    newScrollY: newScrollY,
                    newOpticalScale: newOpticalScale,
                    newOpticalAnchorScreen: newOpticalAnchorScreen
                )
            }
        }

        syncVisibleTiles(
            forceReconfigure: forceReconfigureExisting,
            forceReloadImages: forceReloadImages,
            targetedReloadIDs: targetedReloadIDs,
            animateMoves: animate && !isLiveScrolling,
            animateNewTiles: animate && !isLiveScrolling,
            animationDuration: animationDuration,
            timingFunction: timingFunction,
            isPaneTransition: isPaneTransition,
            compensatedFromRects: compensatedFromRects.isEmpty ? nil : compensatedFromRects,
            anchorAssetID: anchorID
        )
        return newOpticalAnchorScreen
    }

    private func recomputeLayout(
        animate: Bool,
        animateNewTiles: Bool = false,
        animationDuration: CFTimeInterval = 0.26,
        reconfigureExisting: Bool = true,
        forceReloadImages: Bool = false,
        targetedReloadIDs: Set<UUID>? = nil
    ) {
        let clipBounds = enclosingScrollView?.contentView.bounds ?? bounds
        let width = activeContainerWidth()
        lastLayoutWidth = width

        let effectiveWidth = effectiveLayoutTargetWidth(for: targetColumnWidth, mode: layoutMode)
        if layoutMode == .horizontalJustified {
            lastAppliedJustifiedWidth = effectiveWidth
        }

        var oldRects: [UUID: CGRect]? = nil
        if animate && !isLiveScrolling && !activeTiles.isEmpty {
            var snap: [UUID: CGRect] = [:]
            snap.reserveCapacity(activeTiles.count)
            for (id, tile) in activeTiles {
                snap[id] = tile.layer.presentation()?.frame ?? tile.frame
            }
            oldRects = snap
        }

        layoutRecomputeCountForTesting &+= 1
        layout = MasonryLayoutEngine.compute(
            assets: assets,
            layoutMode: layoutMode,
            containerWidth: width,
            targetColumnWidth: effectiveWidth,
            spacing: spacing,
            horizontalPadding: horizontalPadding,
            topInset: topInset,
            bottomInset: bottomInset
        )

        updateDocumentHeight(clipHeight: clipBounds.height)
        syncVisibleTiles(
            forceReconfigure: reconfigureExisting,
            forceReloadImages: forceReloadImages,
            targetedReloadIDs: targetedReloadIDs,
            animateMoves: animate && !isLiveScrolling,
            animateNewTiles: animateNewTiles && !isLiveScrolling,
            animationDuration: animationDuration,
            compensatedFromRects: oldRects
        )
    }

    private func updateDocumentHeight(clipHeight: CGFloat) {
        let clipWidth = enclosingScrollView?.contentView.bounds.width ?? 0
        // Never shrink document width below live clipWidth (prevents AppKit re-entrant sub-pixel
        // frameDidChange loops), and preserve full width while a drawer shrink animation is in flight
        // so inward-gliding cards near the trailing edge are never clipped mid-slide.
        let targetWidth: CGFloat = isInPaneTransition
            ? max(240, max(lastLayoutWidth, max(ceil(clipWidth), frame.width)))
            : max(240, max(lastLayoutWidth, ceil(clipWidth)))
        let targetHeight = max(layout.totalHeight, max(1, clipHeight))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if abs(frame.width - targetWidth) >= 0.5 || abs(frame.height - targetHeight) >= 0.5 {
            setFrameSize(NSSize(width: targetWidth, height: targetHeight))
        }
        // Always mutate bounds+position (never frame) so any active optical pinch transform stays intact
        tilesContainerLayer.bounds = CGRect(origin: .zero, size: CGSize(width: targetWidth, height: targetHeight))
        tilesContainerLayer.position = .zero
        CATransaction.commit()
    }

    private func syncVisibleTiles(
        forceReconfigure: Bool = false,
        forceReloadImages: Bool = false,
        targetedReloadIDs: Set<UUID>? = nil,
        animateMoves: Bool = false,
        animateNewTiles: Bool = false,
        animationDuration: CFTimeInterval = 0.26,
        timingFunction: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0),
        isPaneTransition: Bool = false,
        compensatedFromRects: [UUID: CGRect]? = nil,
        anchorAssetID: UUID? = nil
    ) {
        let vis = visibleRect
        guard vis.height > 0 || !assets.isEmpty else { return }
        let minY = max(0, vis.minY - tileOverscan)
        let maxY = vis.maxY + tileOverscan

        visibleFramesScratch.removeAll(keepingCapacity: true)
        neededIDsScratch.removeAll(keepingCapacity: true)
        layout.forEachVisibleItem(minY: minY, maxY: maxY) { item in
            visibleFramesScratch.append(item)
            neededIDsScratch.insert(item.id)
        }

        // Far-jump settle threshold: non-anchor cards wrapping wildly across columns softly settle in place
        // instead of flying diagonally over 10 other cards. During drawer transitions, allow a wider glide
        // distance and keep opacity >= 0.35 on far wraps so mounted artwork never flashes blank.
        let maxGlideDistance: CGFloat = isPaneTransition
            ? max(layout.columnWidth * 2.15, 420)
            : max(layout.columnWidth * 1.55, 290)
        let wrapFromOpacity: Float = isPaneTransition ? 0.35 : 0.0
        let wrapFromScale: CGFloat = isPaneTransition ? 0.985 : 0.96

        let scale = currentScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Collect & recycle offscreen tiles without mutating `activeTiles` during iteration
        //    (avoids Copy-on-Write dictionary clones) and strictly enforce `maxReusePoolSize`.
        recycleIDsScratch.removeAll(keepingCapacity: true)
        for id in activeTiles.keys where !neededIDsScratch.contains(id) {
            recycleIDsScratch.append(id)
        }
        for id in recycleIDsScratch {
            if let tile = activeTiles.removeValue(forKey: id) {
                tile.prepareForReuse()
                tile.layer.removeFromSuperlayer()
                if reusePool.count < maxReusePoolSize {
                    reusePool.append(tile)
                }
            }
        }

        // 2. Mount or update visible tiles
        for itemFrame in visibleFramesScratch {
            guard itemFrame.index < assets.count else { continue }
            let asset = assets[itemFrame.index]
            guard asset.id == itemFrame.id else { continue }

            let isSelected = selectedAssetIDs.contains(asset.id)
            let isCut = cutAssetIDs.contains(asset.id)
            let isHidden = (activeQuickLookID == asset.id)
            let isAnchorTile = (anchorAssetID != nil && asset.id == anchorAssetID)

            if let existing = activeTiles[asset.id] {
                let rawPrevious = existing.frame
                let fromRect = compensatedFromRects?[asset.id] ?? rawPrevious
                let targetZ: CGFloat = (animateMoves && isAnchorTile) ? 40 : 0
                if existing.layer.zPosition != targetZ {
                    existing.layer.zPosition = targetZ
                }
                let shouldReloadThisTile = forceReloadImages || (targetedReloadIDs?.contains(asset.id) == true)
                if forceReconfigure || shouldReloadThisTile || (!isLiveScrolling && existing.needsDeferredProceduralRender) {
                    existing.configure(
                        asset: asset,
                        frame: itemFrame.rect,
                        isSelected: isSelected,
                        isCut: isCut,
                        isHiddenForHero: isHidden,
                        isDark: isDarkMode,
                        scale: scale,
                        loader: loader,
                        forceReloadImage: shouldReloadThisTile,
                        isLiveScrolling: isLiveScrolling
                    )
                    if animateMoves && fromRect != itemFrame.rect {
                        let dist = hypot(itemFrame.rect.midX - fromRect.midX, itemFrame.rect.midY - fromRect.midY)
                        if isAnchorTile || dist <= maxGlideDistance {
                            existing.animateFrameTransition(
                                from: fromRect,
                                to: itemFrame.rect,
                                duration: animationDuration,
                                timingFunction: timingFunction
                            )
                        } else {
                            existing.animateEnter(
                                duration: min(0.24, animationDuration),
                                fromOpacity: wrapFromOpacity,
                                fromScale: wrapFromScale,
                                timingFunction: timingFunction
                            )
                        }
                    }
                } else if rawPrevious != itemFrame.rect || (animateMoves && fromRect != itemFrame.rect) {
                    existing.updateFrameOnly(itemFrame.rect)
                    if animateMoves && fromRect != itemFrame.rect {
                        let dist = hypot(itemFrame.rect.midX - fromRect.midX, itemFrame.rect.midY - fromRect.midY)
                        if isAnchorTile || dist <= maxGlideDistance {
                            existing.animateFrameTransition(
                                from: fromRect,
                                to: itemFrame.rect,
                                duration: animationDuration,
                                timingFunction: timingFunction
                            )
                        } else {
                            existing.animateEnter(
                                duration: min(0.24, animationDuration),
                                fromOpacity: wrapFromOpacity,
                                fromScale: wrapFromScale,
                                timingFunction: timingFunction
                            )
                        }
                    }
                }
            } else {
                let tile = reusePool.popLast() ?? MasonryTileLayer()
                let shouldReloadThisTile = forceReloadImages || (targetedReloadIDs?.contains(asset.id) == true)
                tile.layer.zPosition = (animateMoves && isAnchorTile) ? 40 : 0
                tile.configure(
                    asset: asset,
                    frame: itemFrame.rect,
                    isSelected: isSelected,
                    isCut: isCut,
                    isHiddenForHero: isHidden,
                    isDark: isDarkMode,
                    scale: scale,
                    loader: loader,
                    forceReloadImage: shouldReloadThisTile,
                    isLiveScrolling: isLiveScrolling
                )
                tilesContainerLayer.addSublayer(tile.layer)
                if animateNewTiles {
                    tile.animateEnter(
                        duration: min(0.22, animationDuration),
                        fromOpacity: isPaneTransition ? 0.25 : 0.0,
                        fromScale: wrapFromScale,
                        timingFunction: timingFunction
                    )
                }
                activeTiles[asset.id] = tile
            }
        }

        // Keep hover overlay & muted hover media preview aligned if still visible and not live-scrolling/pinching/reflowing/covered
        if !isOverlayPresented, !isLiveScrolling, !isPinching, !isInPaneTransition, let hoveredID = hoveredAssetID, let tile = activeTiles[hoveredID], let asset = tile.boundAsset {
            hoverOverlayLayer.show(
                for: asset,
                in: tile.frame,
                isSelected: selectedAssetIDs.contains(hoveredID),
                isDark: isDarkMode,
                scale: scale
            )
            syncHoverMediaPreview(for: asset, in: tile.frame, scale: scale)
        } else if hoveredAssetID != nil {
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
        }

        CATransaction.commit()

        // 3. Background lookahead prefetching in scroll direction (deduped across 120Hz scroll ticks)
        if let loader, !loader.isLowResourceMode {
            let lookMin = scrollingDown ? maxY : max(0, minY - prefetchLookahead)
            let lookMax = scrollingDown ? (maxY + prefetchLookahead) : minY
            if lookMax > lookMin {
                prefetchIDsScratch.removeAll(keepingCapacity: true)
                layout.forEachVisibleItem(minY: lookMin, maxY: lookMax) { item in
                    if prefetchIDsScratch.count < maxPrefetchBatch {
                        prefetchIDsScratch.append(item.id)
                    }
                }
                if !prefetchIDsScratch.isEmpty && prefetchIDsScratch != lastPrefetchIDs {
                    lastPrefetchIDs = prefetchIDsScratch
                    loader.prefetch(assetIDs: prefetchIDsScratch, tier: .grid520)
                }
            }
        }
    }

    private func updateVisibleTileStatesOnly() {
        let scale = currentScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, tile) in activeTiles {
            tile.updateVisualStates(
                isSelected: selectedAssetIDs.contains(id),
                isCut: cutAssetIDs.contains(id),
                isHiddenForHero: activeQuickLookID == id,
                isDark: isDarkMode,
                scale: scale
            )
        }
        if !isOverlayPresented, !isLiveScrolling, !isInPaneTransition, let hoveredID = hoveredAssetID, let tile = activeTiles[hoveredID], let asset = tile.boundAsset {
            hoverOverlayLayer.show(
                for: asset,
                in: tile.frame,
                isSelected: selectedAssetIDs.contains(hoveredID),
                isDark: isDarkMode,
                scale: scale
            )
        }
        CATransaction.commit()
    }

    // MARK: - O(log N) Hit Testing & Hover

    private func hitTestCard(at point: CGPoint) -> (asset: AssetRecord, frame: CGRect)? {
        var matched: (asset: AssetRecord, frame: CGRect)?
        layout.forEachVisibleItem(minY: point.y - 2, maxY: point.y + 2) { item in
            guard matched == nil, item.rect.contains(point), item.index < assets.count else { return }
            let asset = assets[item.index]
            if asset.id == item.id {
                matched = (asset, item.rect)
            }
        }
        return matched
    }

    private func syncHoverMediaPreview(for asset: AssetRecord?, in frame: CGRect?, scale: CGFloat) {
        guard !isOverlayPresented,
              !isLiveScrolling,
              activeQuickLookID == nil,
              window?.occlusionState.contains(.visible) != false,
              NSApp?.isHidden != true,
              let asset,
              let frame,
              let loader,
              HoverMediaPreviewLayerController.supportsHoverPlayback(asset) else {
            hoverMediaPreview.stop()
            return
        }
        hoverMediaPreview.schedulePreview(
            for: asset,
            in: frame,
            cornerRadius: 12,
            fillMode: true,
            scale: scale,
            loader: loader
        )
    }

    private func refreshHoverForCurrentMouseLocation() {
        guard !isOverlayPresented, !isLiveScrolling, !isPinching, !isInPaneTransition, let window else {
            hoveredAssetID = nil
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
            return
        }
        guard window.occlusionState.contains(.visible), NSApp?.isHidden != true else {
            hoveredAssetID = nil
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
            return
        }
        let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(loc), let hit = hitTestCard(at: loc) else {
            hoveredAssetID = nil
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
            return
        }
        hoveredAssetID = hit.asset.id
        let scale = currentScale
        hoverOverlayLayer.show(
            for: hit.asset,
            in: hit.frame,
            isSelected: selectedAssetIDs.contains(hit.asset.id),
            isDark: isDarkMode,
            scale: scale
        )
        syncHoverMediaPreview(for: hit.asset, in: hit.frame, scale: scale)
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isOverlayPresented, !isLiveScrolling, !isPinching, !isInPaneTransition else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hitTestCard(at: point) else {
            if hoveredAssetID != nil {
                hoveredAssetID = nil
                hoverOverlayLayer.hide()
                hoverMediaPreview.stop()
            }
            return
        }
        if hoveredAssetID != hit.asset.id || hoverOverlayLayer.isHidden {
            hoveredAssetID = hit.asset.id
            let scale = currentScale
            hoverOverlayLayer.show(
                for: hit.asset,
                in: hit.frame,
                isSelected: selectedAssetIDs.contains(hit.asset.id),
                isDark: isDarkMode,
                scale: scale
            )
            syncHoverMediaPreview(for: hit.asset, in: hit.frame, scale: scale)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredAssetID = nil
        hoverOverlayLayer.hide()
        hoverMediaPreview.stop()
    }

    // MARK: - Selection, Double-Click, Marquee & Drag Out

    private func commitSelection(_ newSelection: Set<UUID>) {
        guard selectedAssetIDs != newSelection else { return }
        sessionZoomAnchor = nil
        selectedAssetIDs = newSelection
        updateVisibleTileStatesOnly()
        onSelectionChanged?(newSelection)
    }

    private func effectiveSelection(including id: UUID) -> [UUID] {
        guard selectedAssetIDs.contains(id) else {
            return [id]
        }
        if selectedAssetIDs.count == 1 {
            return [id]
        }
        // O(K log K) via `assetIndexByID` when selection is smaller than the full library,
        // avoiding an O(N) scan across 10,000+ assets on every right-click or drag start.
        if selectedAssetIDs.count * 4 < assets.count {
            var indexed: [(index: Int, id: UUID)] = []
            var unindexed: [UUID] = []
            indexed.reserveCapacity(selectedAssetIDs.count)
            for candidate in selectedAssetIDs where candidate != id {
                if let idx = assetIndexByID[candidate] {
                    indexed.append((idx, candidate))
                } else {
                    unindexed.append(candidate)
                }
            }
            indexed.sort { $0.index < $1.index }
            var ordered: [UUID] = []
            ordered.reserveCapacity(selectedAssetIDs.count)
            ordered.append(id)
            for pair in indexed { ordered.append(pair.id) }
            for extra in unindexed { ordered.append(extra) }
            return ordered
        }

        var ordered: [UUID] = []
        ordered.reserveCapacity(selectedAssetIDs.count)
        ordered.append(id)
        for asset in assets where asset.id != id && selectedAssetIDs.contains(asset.id) {
            ordered.append(asset.id)
        }
        if ordered.count < selectedAssetIDs.count {
            let seen = Set(ordered)
            for remaining in selectedAssetIDs where !seen.contains(remaining) {
                ordered.append(remaining)
            }
        }
        return ordered
    }

    private func applyCardClick(asset: AssetRecord, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            var next = selectedAssetIDs
            if next.contains(asset.id) { next.remove(asset.id) } else { next.insert(asset.id) }
            commitSelection(next)
        } else if modifiers.contains(.shift), let anchorID = lastClickedID,
                  let a = assetIndexByID[anchorID], let b = assetIndexByID[asset.id] {
            let lo = min(a, b)
            let hi = max(a, b)
            var next = selectedAssetIDs
            for idx in lo...hi where idx < assets.count {
                next.insert(assets[idx].id)
            }
            commitSelection(next)
        } else {
            commitSelection([asset.id])
        }
        lastClickedID = asset.id
    }

    override func mouseDown(with event: NSEvent) {
        hoverMediaPreview.stop()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if let hit = hitTestCard(at: point) {
            // Check top-left 30x30 checkbox tap zone
            let checkboxRect = CGRect(x: hit.frame.minX, y: hit.frame.minY, width: 32, height: 32)
            if checkboxRect.contains(point) && (hoveredAssetID == hit.asset.id || selectedAssetIDs.contains(hit.asset.id)) {
                var next = selectedAssetIDs
                if next.contains(hit.asset.id) { next.remove(hit.asset.id) } else { next.insert(hit.asset.id) }
                lastClickedID = hit.asset.id
                commitSelection(next)
                pointerMode = .none
                return
            }

            if event.clickCount == 2 {
                callbacks.onOpenQuickLook(hit.asset)
                pointerMode = .none
                return
            }

            pointerMode = .pendingCard(asset: hit.asset, frame: hit.frame, startPoint: point, event: event)
        } else {
            let mods = event.modifierFlags
            let base = (mods.contains(.command) || mods.contains(.shift)) ? selectedAssetIDs : []
            pointerMode = .marquee(startPoint: point, baseSelection: base)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch pointerMode {
        case .none:
            break
        case .pendingCard(let asset, let cardFrame, let startPoint, let downEvent):
            let dx = point.x - startPoint.x
            let dy = point.y - startPoint.y
            guard (dx * dx + dy * dy) >= 25 else { return }
            pointerMode = .none
            startCardDragSession(asset: asset, cardFrame: cardFrame, event: downEvent)

        case .marquee(let startPoint, let baseSelection):
            lastMarqueeEvent = event
            autoscroll(with: event)
            updateMarqueeSelection(startPoint: startPoint, currentPoint: point, baseSelection: baseSelection)
            if !visibleRect.contains(point) {
                startMarqueeAutoscrollTimerIfNeeded()
            } else {
                marqueeAutoscrollTimer?.invalidate()
                marqueeAutoscrollTimer = nil
            }
        }
    }

    private func updateMarqueeSelection(startPoint: CGPoint, currentPoint: CGPoint, baseSelection: Set<UUID>) {
        let rect = CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marqueeLayer.frame = rect
        marqueeLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.11).cgColor
        marqueeLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.68).cgColor
        marqueeLayer.isHidden = (rect.width <= 3 && rect.height <= 3)
        CATransaction.commit()

        var next = baseSelection
        next.formUnion(layout.intersectingIDs(in: rect))
        commitSelection(next)
    }

    private func startMarqueeAutoscrollTimerIfNeeded() {
        guard marqueeAutoscrollTimer == nil else { return }
        marqueeAutoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.032, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      case .marquee(let startPoint, let baseSelection) = self.pointerMode,
                      let event = self.lastMarqueeEvent,
                      let window = self.window else {
                    self?.stopMarqueeAutoscrollTimer()
                    return
                }
                let liveWindowPt = window.mouseLocationOutsideOfEventStream
                let docPt = self.convert(liveWindowPt, from: nil)
                if !self.visibleRect.contains(docPt) {
                    _ = self.autoscroll(with: event)
                    let updatedDocPt = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    self.updateMarqueeSelection(startPoint: startPoint, currentPoint: updatedDocPt, baseSelection: baseSelection)
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopMarqueeAutoscrollTimer()
        switch pointerMode {
        case .none:
            break
        case .pendingCard(let asset, _, _, _):
            applyCardClick(asset: asset, modifiers: event.modifierFlags)
        case .marquee(_, let baseSelection):
            if marqueeLayer.isHidden, selectedAssetIDs != baseSelection {
                commitSelection(baseSelection)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            marqueeLayer.isHidden = true
            CATransaction.commit()
        }
        pointerMode = .none
    }

    private func startCardDragSession(asset: AssetRecord, cardFrame: CGRect, event: NSEvent) {
        let ids = effectiveSelection(including: asset.id)
        let previewSize = CGSize(width: min(120, max(64, cardFrame.width)), height: min(120, max(64, cardFrame.height)))
        let baseOrigin = CGPoint(x: cardFrame.midX - previewSize.width * 0.5, y: cardFrame.midY - previewSize.height * 0.5)

        // Item 0 ALWAYS carries ALL selected IDs for instant internal folder/moodboard drops (even 1,000+ items).
        // Additional NSDraggingItems carry local file URLs (capped to 32) for dragging multiple files out to Finder/apps.
        let maxExternalDragItems = 32
        let maxVisibleStackPreviews = 4
        let tinyPlaceholder = NSImage(size: NSSize(width: 2, height: 2))

        var dragItems: [NSDraggingItem] = []
        dragItems.reserveCapacity(min(ids.count, maxExternalDragItems))

        for (idx, id) in ids.prefix(maxExternalDragItems).enumerated() {
            let pbItem = NSPasteboardItem()
            if idx == 0 {
                pbItem.setString(CharkleDragIdentifiers.encode(assetIDs: ids), forType: .string)
            }
            if let localURL = callbacks.onResolveDragFileURL(id) {
                pbItem.setString(localURL.absoluteString, forType: .fileURL)
            } else if idx > 0 {
                continue
            }
            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            if idx < maxVisibleStackPreviews {
                let img = loader?.cachedImage(for: id, tier: .grid520) ?? NSImage(size: previewSize)
                let offset = CGFloat(idx) * 6
                dragItem.setDraggingFrame(
                    CGRect(x: baseOrigin.x + offset, y: baseOrigin.y + offset, width: previewSize.width, height: previewSize.height),
                    contents: img
                )
            } else {
                dragItem.setDraggingFrame(
                    CGRect(x: baseOrigin.x + 18, y: baseOrigin.y + 18, width: 2, height: 2),
                    contents: tinyPlaceholder
                )
            }
            dragItems.append(dragItem)
        }
        guard !dragItems.isEmpty else { return }
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.draggingFormation = ids.count > 1 ? .pile : .default
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    // MARK: - External Drop Destination

    private func isInternalCharkleDrag(_ pasteboard: NSPasteboard) -> Bool {
        let changeCount = pasteboard.changeCount
        if changeCount != cachedDragChangeCount {
            cachedDragChangeCount = changeCount
            if let str = pasteboard.string(forType: .string), CharkleDragIdentifiers.isInternalDrag(str) {
                cachedDragIsInternal = true
            } else {
                cachedDragIsInternal = false
            }
        }
        return cachedDragIsInternal
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !isInternalCharkleDrag(sender.draggingPasteboard) else { return [] }
        onExternalDropTargetedChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !isInternalCharkleDrag(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onExternalDropTargetedChanged?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onExternalDropTargetedChanged?(false)
        let pb = sender.draggingPasteboard
        guard !isInternalCharkleDrag(pb) else { return false }

        var inputs: [CaptureInput] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls {
                inputs.append(.fileURL(url))
            }
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  let webURL = urls.first(where: { WebBookmark.isWebURL($0) }) {
            inputs.append(.webURL(webURL, title: nil, notes: nil))
        } else if let rawURLStr = pb.string(forType: .URL) ?? pb.string(forType: NSPasteboard.PasteboardType("public.url")),
                  let url = WebURLParser.parse(rawURLStr) {
            inputs.append(.webURL(url, title: nil, notes: nil))
        } else if let plist = pb.propertyList(forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")) as? [[String]],
                  let firstURL = plist.first?.first,
                  let url = WebURLParser.parse(firstURL) {
            inputs.append(.webURL(url, title: nil, notes: nil))
        } else if let png = pb.data(forType: .png) {
            inputs.append(.imageData(png, suggestedName: "Drop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            inputs.append(.imageData(png, suggestedName: "Drop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
        } else if let str = pb.string(forType: .string) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let socialURL = SocialPostURLParser.extractPostURL(from: trimmed) {
                inputs.append(.webURL(socialURL, title: nil, notes: nil))
            } else if let githubURL = GitHubRepoURLParser.extractRepoURL(from: trimmed) {
                inputs.append(.webURL(githubURL, title: nil, notes: nil))
            } else if let webURL = WebURLParser.extractWebURL(from: trimmed) {
                inputs.append(.webURL(webURL, title: nil, notes: nil))
            } else if !trimmed.isEmpty {
                let title = String(trimmed.prefix(36)).replacingOccurrences(of: "\n", with: " ")
                inputs.append(.textSnippet(title: title, text: trimmed, sourceURL: nil))
            }
        }

        guard !inputs.isEmpty else { return false }
        callbacks.onDropExternalInputs(inputs)
        return true
    }

    // MARK: - Lazy Right-Click Context Menu (Zero Per-Card Allocation During Scroll)

    private func makeMenuItem(title: String, symbol: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
        let target = MasonryMenuActionTarget(action)
        let item = NSMenuItem(title: title, action: #selector(MasonryMenuActionTarget.performAction), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()

        guard let hit = hitTestCard(at: point) else {
            menu.addItem(makeMenuItem(title: "粘贴", symbol: "doc.on.clipboard") { [weak self] in
                self?.callbacks.onPasteIntoCurrentFolder()
            })
            return menu
        }

        let asset = hit.asset
        let targets = effectiveSelection(including: asset.id)

        menu.addItem(makeMenuItem(
            title: asset.isExternalWebLink ? "在默认浏览器中打开 (Space)" : "快速预览 (Space)",
            symbol: asset.isExternalWebLink ? "safari" : "eye"
        ) { [weak self] in
            self?.callbacks.onOpenQuickLook(asset)
        })
        menu.addItem(makeMenuItem(title: "在访达中显示", symbol: "folder") { [weak self] in
            self?.callbacks.onRevealInFinder(asset.id)
        })

        if asset.isTrashed {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: "放回原处", symbol: "arrow.uturn.backward") { [weak self] in
                self?.callbacks.onRestoreAssets(targets)
            })
            menu.addItem(makeMenuItem(title: "彻底删除", symbol: "trash.slash") { [weak self] in
                self?.callbacks.onPermanentlyDeleteAssets(targets)
            })
        } else {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: "拷贝", symbol: "doc.on.doc") { [weak self] in
                self?.callbacks.onCopyAssets(targets)
            })
            menu.addItem(makeMenuItem(title: "剪切", symbol: "scissors") { [weak self] in
                self?.callbacks.onCutAssets(targets)
            })
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: "加入情绪板…", symbol: "rectangle.3.group") { [weak self] in
                self?.callbacks.onAddToMoodboard(targets)
            })

            let pureRefItem = NSMenuItem(
                title: targets.count > 1 ? "发送到 PureRef（\(targets.count) 项）" : "发送到 PureRef",
                action: nil,
                keyEquivalent: ""
            )
            pureRefItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
            let pureRefSubmenu = NSMenu()
            pureRefSubmenu.addItem(makeMenuItem(title: "在 PureRef 中打开", symbol: "arrow.up.forward.app") { [weak self] in
                self?.callbacks.onOpenInPureRef(targets)
            })
            pureRefSubmenu.addItem(makeMenuItem(title: "导出为 PureRef (.pur)…", symbol: "square.and.arrow.up") { [weak self] in
                self?.callbacks.onExportToPureRef(targets)
            })
            pureRefItem.submenu = pureRefSubmenu
            menu.addItem(pureRefItem)
            menu.addItem(makeMenuItem(
                title: targets.count > 1 ? "AI 批量重新打标（\(targets.count) 项）" : "AI 重新打标",
                symbol: "sparkles"
            ) { [weak self] in
                self?.callbacks.onRetagAssets(targets)
            })

            let moveItem = NSMenuItem(title: "移动到文件夹", action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
            let moveSubmenu = NSMenu()
            let currentSingleFolderID: UUID? = targets.count == 1 ? asset.folderID : nil
            let highlightCurrent = targets.count == 1
            let inboxItem = makeMenuItem(title: "收件箱", symbol: "tray") { [weak self] in
                self?.callbacks.onMoveToFolder(targets, nil)
            }
            if highlightCurrent && currentSingleFolderID == nil {
                inboxItem.state = .on
            }
            moveSubmenu.addItem(inboxItem)
            let folderRoots = FolderHierarchyNode.buildTree(from: folders)
            if !folderRoots.isEmpty {
                moveSubmenu.addItem(.separator())
                populateHierarchicalFolderMenu(
                    moveSubmenu,
                    nodes: folderRoots,
                    targets: targets,
                    currentFolderID: highlightCurrent ? currentSingleFolderID : nil,
                    highlightCurrent: highlightCurrent
                )
            }
            moveItem.submenu = moveSubmenu
            menu.addItem(moveItem)

            menu.addItem(makeMenuItem(
                title: asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地",
                symbol: asset.pinnedOffline ? "icloud" : "arrow.down.circle"
            ) { [weak self] in
                self?.callbacks.onTogglePinOffline(targets, !asset.pinnedOffline)
            })

            if let hex = asset.dominantColors.first?.hex.uppercased() {
                menu.addItem(makeMenuItem(title: "复制主色 \(hex)", symbol: "paintpalette") { [weak self] in
                    self?.callbacks.onCopyColorHex(hex)
                })
            }

            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: "移至废纸篓", symbol: "trash") { [weak self] in
                self?.callbacks.onTrashAssets(targets)
            })
        }
        return menu
    }

    private func populateHierarchicalFolderMenu(
        _ menu: NSMenu,
        nodes: [FolderHierarchyNode],
        targets: [UUID],
        currentFolderID: UUID?,
        highlightCurrent: Bool
    ) {
        for node in nodes {
            let folder = node.folder
            if node.hasChildren {
                let isBranchSelected = highlightCurrent && node.contains(folderID: currentFolderID)
                let parentItem = NSMenuItem(
                    title: isBranchSelected ? "\(folder.name) •" : folder.name,
                    action: nil,
                    keyEquivalent: ""
                )
                parentItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

                let submenu = NSMenu()
                let selfItem = makeMenuItem(title: "放入「\(folder.name)」", symbol: "folder.badge.plus") { [weak self] in
                    self?.callbacks.onMoveToFolder(targets, folder.id)
                }
                if highlightCurrent && currentFolderID == folder.id {
                    selfItem.state = .on
                }
                submenu.addItem(selfItem)
                submenu.addItem(.separator())
                populateHierarchicalFolderMenu(
                    submenu,
                    nodes: node.children,
                    targets: targets,
                    currentFolderID: currentFolderID,
                    highlightCurrent: highlightCurrent
                )
                parentItem.submenu = submenu
                menu.addItem(parentItem)
            } else {
                let leafItem = makeMenuItem(title: folder.name, symbol: "folder") { [weak self] in
                    self?.callbacks.onMoveToFolder(targets, folder.id)
                }
                if highlightCurrent && currentFolderID == folder.id {
                    leafItem.state = .on
                }
                menu.addItem(leafItem)
            }
        }
    }

    // MARK: - Keyboard Shortcuts (When Masonry Is Focused)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        // Ignore Caps Lock / NumPad / Function flags so ⌘A/⌘C/⌘X/⌘V work reliably with Chinese IME switch
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "a":
                commitSelection(Set(assets.map(\.id)))
                return true
            case "c":
                guard !selectedAssetIDs.isEmpty else { return false }
                callbacks.onCopyAssets(Array(selectedAssetIDs))
                return true
            case "x":
                guard !selectedAssetIDs.isEmpty else { return false }
                callbacks.onCutAssets(Array(selectedAssetIDs))
                return true
            case "v":
                callbacks.onPasteIntoCurrentFolder()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let primaryModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // 2D spatial arrow-key navigation (with optional Shift range extension)
        let navDirection: MasonryLayoutEngine.NavigationDirection? = switch event.keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
        if let navDirection, (primaryModifiers.isEmpty || primaryModifiers == [.shift]), !assets.isEmpty {
            navigateSelection(direction: navDirection, extendSelection: primaryModifiers.contains(.shift))
            return
        }

        guard primaryModifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Escape
            if !selectedAssetIDs.isEmpty {
                commitSelection([])
                return
            }
        case 36, 76: // Return / Enter -> Open Quick Look for selected item
            guard activeQuickLookID == nil, !isOverlayPresented else { return }
            if event.isARepeat { return }
            if let anchor = lastClickedID, let idx = assetIndexByID[anchor], idx < assets.count, selectedAssetIDs.contains(anchor) {
                callbacks.onOpenQuickLook(assets[idx])
                return
            }
            if let firstIdx = selectedAssetIDs.compactMap({ assetIndexByID[$0] }).min(), firstIdx < assets.count {
                callbacks.onOpenQuickLook(assets[firstIdx])
                return
            }
        case 49: // Space (fallback when used standalone outside MainWindowView)
            guard activeQuickLookID == nil, !isOverlayPresented else { return }
            if event.isARepeat { return }
            if let firstIdx = selectedAssetIDs.compactMap({ assetIndexByID[$0] }).min(), firstIdx < assets.count {
                callbacks.onOpenQuickLook(assets[firstIdx])
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    private func navigateSelection(direction: MasonryLayoutEngine.NavigationDirection, extendSelection: Bool) {
        guard !assets.isEmpty, !layout.items.isEmpty else { return }

        let currentIndex: Int? = {
            if let lastID = lastClickedID, selectedAssetIDs.contains(lastID), let idx = assetIndexByID[lastID] {
                return idx
            }
            return selectedAssetIDs.compactMap { assetIndexByID[$0] }.min()
        }()

        let targetIndex: Int
        if let currentIndex,
           let nextIdx = MasonryLayoutEngine.nextAssetIndex(from: currentIndex, direction: direction, in: layout) {
            targetIndex = nextIdx
        } else {
            targetIndex = 0
        }
        guard targetIndex >= 0, targetIndex < assets.count else { return }
        let targetAsset = assets[targetIndex]

        if extendSelection {
            var next = selectedAssetIDs
            next.insert(targetAsset.id)
            commitSelection(next)
        } else {
            commitSelection([targetAsset.id])
        }
        lastClickedID = targetAsset.id
        scrollItemIntoVisibleArea(at: targetIndex)
    }

    private func scrollItemIntoVisibleArea(at index: Int) {
        guard index < layout.items.count, let clipView = enclosingScrollView?.contentView else { return }
        let itemRect = layout.items[index].rect
        let clipBounds = clipView.bounds
        let safeTop = clipBounds.minY + topInset + 8
        let safeBottom = clipBounds.maxY - min(bottomInset, clipBounds.height * 0.25) - 8
        var nextScrollY = clipBounds.origin.y
        if itemRect.minY < safeTop {
            nextScrollY = max(0, itemRect.minY - topInset - 12)
        } else if itemRect.maxY > safeBottom {
            let maxScrollY = max(0, layout.totalHeight - clipBounds.height)
            let usableBottom = max(80, clipBounds.height - min(bottomInset, clipBounds.height * 0.25) - 12)
            nextScrollY = min(maxScrollY, max(0, itemRect.maxY - usableBottom))
        } else {
            return
        }
        guard abs(nextScrollY - clipBounds.origin.y) >= 1 else { return }
        clipView.scroll(to: NSPoint(x: 0, y: nextScrollY))
        enclosingScrollView?.reflectScrolledClipView(clipView)
        lastScrollY = nextScrollY
        syncVisibleTiles()
    }
}

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

    public static let empty = MasonryLayoutSnapshot(items: [], totalHeight: 0, columnCount: 1, columnWidth: 240)

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
        let candidates = visibleItems(minY: rect.minY, maxY: rect.maxY)
        var ids: [UUID] = []
        ids.reserveCapacity(candidates.count)
        for item in candidates where item.rect.intersects(rect) {
            ids.append(item.id)
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
        case .verticalMasonry, .galleryFilmstrip:
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
        case .verticalMasonry, .galleryFilmstrip:
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
                asset.pixelWidth > 0 && asset.pixelHeight > 0 ? CGFloat(asset.aspectRatio) : 1.12
            } else if asset.isGitHubRepo {
                1.32
            } else {
                1.25
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
        self.onRetagAssets = onRetagAssets
        self.onTrashAssets = onTrashAssets
        self.onRestoreAssets = onRestoreAssets
        self.onPermanentlyDeleteAssets = onPermanentlyDeleteAssets
        self.onResolveDragFileURL = onResolveDragFileURL
        self.onZoomColumnWidth = onZoomColumnWidth
    }
}

// MARK: - High-FPS Hardware-Accelerated Native AppKit Recycling Masonry View (10k+ Items, 120 FPS)

private struct MasonryAssetsSignature: Equatable {
    let revision: Int
    let count: Int
    let firstID: UUID?
    let lastID: UUID?
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
    public let heroNamespace: Namespace.ID
    public let activeQuickLookID: UUID?
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
        heroNamespace: Namespace.ID,
        activeQuickLookID: UUID? = nil,
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
        self.heroNamespace = heroNamespace
        self.activeQuickLookID = activeQuickLookID
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
                activeQuickLookID: activeQuickLookID,
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
    let activeQuickLookID: UUID?
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
            activeQuickLookID: activeQuickLookID,
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
            activeQuickLookID: activeQuickLookID,
            isDarkMode: isDarkMode,
            reduceMotion: reduceMotion,
            callbacks: callbacks
        )
    }
}

// MARK: - AppKit Scroll Container (with macOS Photos-Style Pinch & ⌘+Scroll Zoom)

private final class MasonryScrollView: NSScrollView {
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
                anchorDocPoint: cursorInDoc
            )
            return
        }
        super.scrollWheel(with: event)
    }

    private func configure() {
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        contentView.drawsBackground = false
        contentView.postsBoundsChangedNotifications = true
        contentView.postsFrameChangedNotifications = true
        documentView = masonryDocument

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.masonryDocument.handleScrollBoundsChanged()
            }
        })
        observers.append(nc.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.masonryDocument.handleViewportFrameChanged()
            }
        })
        observers.append(nc.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrollerStyle = .overlay
                self?.autohidesScrollers = true
            }
        })
        observers.append(nc.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.masonryDocument.setLiveScrolling(true)
            }
        })
        observers.append(nc.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.masonryDocument.setLiveScrolling(false)
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
    init(_ image: CGImage) { self.image = image }
}

private enum MasonryStaticLayerAssets {
    private static let badgeCache = NSCache<NSString, MasonryCGImageBox>()
    private static let proceduralCache: NSCache<NSString, MasonryCGImageBox> = {
        let c = NSCache<NSString, MasonryCGImageBox>()
        c.countLimit = 400
        return c
    }()

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
        "path": NSNull()
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
        badgeCache.setObject(MasonryCGImageBox(cg), forKey: key)
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
        badgeCache.setObject(MasonryCGImageBox(cg), forKey: key)
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
        badgeCache.setObject(MasonryCGImageBox(cg), forKey: key)
        return cg
    }

    static func mediaPillBadge(text: String, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
        let key = "pill-\(text)-\(Int((scale * 10).rounded()))" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pillSize = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 6)
        if let hit = badgeCache.object(forKey: key) {
            return (hit.image, pillSize)
        }
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
        badgeCache.setObject(MasonryCGImageBox(cg), forKey: key)
        return (cg, pillSize)
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
                        if let post = asset.richMetadata?.socialPost { return "@\(post.authorHandle)" }
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

        proceduralCache.setObject(MasonryCGImageBox(cg), forKey: key)
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

    private let clipLayer = CALayer()
    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private let cutDashLayer = CAShapeLayer()
    private let selectedCheckLayer = CALayer()
    private let pinBadgeLayer = CALayer()
    private let mediaBadgeLayer = CALayer()

    init() {
        setupSublayers()
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

        clipLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        clipLayer.cornerRadius = Self.cornerRad
        clipLayer.cornerCurve = .continuous
        clipLayer.masksToBounds = true
        layer.addSublayer(clipLayer)

        imageLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        clipLayer.addSublayer(imageLayer)

        borderLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        borderLayer.cornerRadius = Self.cornerRad
        borderLayer.cornerCurve = .continuous
        borderLayer.backgroundColor = nil
        layer.addSublayer(borderLayer)

        cutDashLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        cutDashLayer.fillColor = nil
        cutDashLayer.lineWidth = 1.25
        cutDashLayer.lineDashPattern = [5, 4]
        cutDashLayer.isHidden = true
        layer.addSublayer(cutDashLayer)

        selectedCheckLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        selectedCheckLayer.contentsGravity = .resizeAspect
        selectedCheckLayer.isHidden = true
        layer.addSublayer(selectedCheckLayer)

        pinBadgeLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        pinBadgeLayer.contentsGravity = .resizeAspect
        pinBadgeLayer.isHidden = true
        layer.addSublayer(pinBadgeLayer)

        mediaBadgeLayer.actions = MasonryStaticLayerAssets.noImplicitActions
        mediaBadgeLayer.contentsGravity = .resizeAspect
        mediaBadgeLayer.isHidden = true
        layer.addSublayer(mediaBadgeLayer)
    }

    var frame: CGRect {
        layer.frame
    }

    func prepareForReuse() {
        loadTask?.cancel()
        loadTask = nil
        stripLayoutAnimations()
        boundAssetID = nil
        boundAsset = nil
        imageLayer.contents = nil
        selectedCheckLayer.isHidden = true
        pinBadgeLayer.isHidden = true
        mediaBadgeLayer.isHidden = true
        cutDashLayer.isHidden = true
        lastBadgeText = nil
    }

    func stripLayoutAnimations() {
        layer.removeAnimation(forKey: "charkle.pos")
        layer.removeAnimation(forKey: "charkle.bounds")
        layer.removeAnimation(forKey: "charkle.shadowPath")
        layer.removeAnimation(forKey: "charkle.enterScale")
        layer.removeAnimation(forKey: "charkle.enterOpacity")
        clipLayer.removeAnimation(forKey: "charkle.pos")
        clipLayer.removeAnimation(forKey: "charkle.bounds")
        imageLayer.removeAnimation(forKey: "charkle.pos")
        imageLayer.removeAnimation(forKey: "charkle.bounds")
        borderLayer.removeAnimation(forKey: "charkle.pos")
        borderLayer.removeAnimation(forKey: "charkle.bounds")
        mediaBadgeLayer.removeAnimation(forKey: "charkle.pos")
        pinBadgeLayer.removeAnimation(forKey: "charkle.pos")
        cutDashLayer.removeAnimation(forKey: "charkle.pos")
        cutDashLayer.removeAnimation(forKey: "charkle.bounds")
    }

    /// GPU-composited Photos-style transition from a scroll/transform-compensated `fromRect` to `newRect`.
    /// Animates card frame, image clip, border, shadow, and right-edge badges in unison with zero jump.
    func animateFrameTransition(from fromRect: CGRect, to newRect: CGRect, duration: CFTimeInterval = 0.28) {
        guard fromRect != newRect, fromRect.width > 1, fromRect.height > 1 else { return }
        let timing = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)

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
        addPair(on: clipLayer, fromP: fromLocalCenter, toP: toLocalCenter, fromB: fromBounds, toB: toBounds)
        addPair(on: imageLayer, fromP: fromLocalCenter, toP: toLocalCenter, fromB: fromBounds, toB: toBounds)
        addPair(on: borderLayer, fromP: fromLocalCenter, toP: toLocalCenter, fromB: fromBounds, toB: toBounds)

        if abs(fromBounds.width - toBounds.width) > 0.25 || abs(fromBounds.height - toBounds.height) > 0.25 {
            let shadowAnim = CABasicAnimation(keyPath: "shadowPath")
            shadowAnim.fromValue = CGPath(roundedRect: fromBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            shadowAnim.toValue = CGPath(roundedRect: toBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            shadowAnim.duration = duration
            shadowAnim.timingFunction = timing
            layer.add(shadowAnim, forKey: "charkle.shadowPath")

            // Keep top-right badges anchored to the card edge during bounds resize
            let deltaW = toBounds.width - fromBounds.width
            if abs(deltaW) > 0.5 {
                if !mediaBadgeLayer.isHidden {
                    let badgeTo = mediaBadgeLayer.position
                    let badgeAnim = CABasicAnimation(keyPath: "position")
                    badgeAnim.fromValue = CGPoint(x: badgeTo.x - deltaW, y: badgeTo.y)
                    badgeAnim.toValue = badgeTo
                    badgeAnim.duration = duration
                    badgeAnim.timingFunction = timing
                    mediaBadgeLayer.add(badgeAnim, forKey: "charkle.pos")
                }
                if !pinBadgeLayer.isHidden {
                    let pinTo = pinBadgeLayer.position
                    let pinAnim = CABasicAnimation(keyPath: "position")
                    pinAnim.fromValue = CGPoint(x: pinTo.x - deltaW, y: pinTo.y)
                    pinAnim.toValue = pinTo
                    pinAnim.duration = duration
                    pinAnim.timingFunction = timing
                    pinBadgeLayer.add(pinAnim, forKey: "charkle.pos")
                }
            }
        }
    }

    /// Quiet Photos-style crossfade settle (`scale(0.96 -> 1.0)` + `opacity(0 -> 1)`) used for newly visible cards
    /// and for cards whose column wrap would otherwise shoot wildly across the entire screen.
    func animateEnter(duration: CFTimeInterval = 0.22) {
        stripLayoutAnimations()
        let timing = CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0)
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.96
        scaleAnim.toValue = 1.0
        scaleAnim.duration = duration
        scaleAnim.timingFunction = timing
        layer.add(scaleAnim, forKey: "charkle.enterScale")

        let opAnim = CABasicAnimation(keyPath: "opacity")
        opAnim.fromValue = 0.0
        opAnim.toValue = 1.0
        opAnim.duration = duration * 0.85
        opAnim.timingFunction = timing
        layer.add(opAnim, forKey: "charkle.enterOpacity")
    }

    /// Fast geometry-only frame update used during sidebar/inspector drawer animations and live window resize,
    /// avoiding redundant selection, badge, color, and thumbnail cache work on every frame.
    func updateFrameOnly(_ rect: CGRect) {
        layer.frame = rect
        let localBounds = CGRect(origin: .zero, size: rect.size)
        clipLayer.frame = localBounds
        imageLayer.frame = localBounds
        borderLayer.frame = localBounds

        if lastShadowSize != rect.size {
            lastShadowSize = rect.size
            layer.shadowPath = CGPath(roundedRect: localBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            cutDashLayer.frame = localBounds
            cutDashLayer.path = CGPath(roundedRect: localBounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
        }

        var rightCursor = rect.width - 6
        if !mediaBadgeLayer.isHidden {
            let w = mediaBadgeLayer.bounds.width
            let h = mediaBadgeLayer.bounds.height
            mediaBadgeLayer.frame = CGRect(x: rightCursor - w, y: 6, width: w, height: h)
            rightCursor -= (w + 4)
        }
        if !pinBadgeLayer.isHidden {
            pinBadgeLayer.frame = CGRect(x: rightCursor - 18, y: 6, width: 18, height: 18)
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
        forceReloadImage: Bool
    ) {
        let sameAsset = (boundAssetID == asset.id)
        boundAssetID = asset.id
        boundAsset = asset
        layer.contentsScale = scale
        clipLayer.contentsScale = scale
        imageLayer.contentsScale = scale

        layer.frame = rect
        let localBounds = CGRect(origin: .zero, size: rect.size)
        clipLayer.frame = localBounds
        imageLayer.frame = localBounds
        borderLayer.frame = localBounds

        let cardSurface = isDark ? NSColor.charkleHex("#1E2024") : NSColor.white
        layer.backgroundColor = cardSurface.cgColor

        if lastShadowSize != rect.size {
            lastShadowSize = rect.size
            layer.shadowPath = CGPath(roundedRect: localBounds, cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
            cutDashLayer.frame = localBounds
            cutDashLayer.path = CGPath(roundedRect: localBounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.cornerRad, cornerHeight: Self.cornerRad, transform: nil)
        }

        // Selection & cut visuals
        updateVisualStates(isSelected: isSelected, isCut: isCut, isHiddenForHero: isHiddenForHero, isDark: isDark, scale: scale)

        // Badges (top-right)
        var rightCursor = rect.width - 6
        let badgeText = Self.mediaBadgeText(for: asset)
        if let badgeText {
            if lastBadgeText != badgeText || mediaBadgeLayer.contents == nil,
               let pill = MasonryStaticLayerAssets.mediaPillBadge(text: badgeText, scale: scale) {
                mediaBadgeLayer.contents = pill.image
                mediaBadgeLayer.contentsScale = scale
                mediaBadgeLayer.frame = CGRect(x: rightCursor - pill.size.width, y: 6, width: pill.size.width, height: pill.size.height)
                lastBadgeText = badgeText
            } else {
                let w = mediaBadgeLayer.bounds.width
                let h = mediaBadgeLayer.bounds.height
                mediaBadgeLayer.frame = CGRect(x: rightCursor - w, y: 6, width: w, height: h)
            }
            mediaBadgeLayer.isHidden = false
            rightCursor -= (mediaBadgeLayer.frame.width + 4)
        } else {
            mediaBadgeLayer.isHidden = true
            lastBadgeText = nil
        }

        if asset.pinnedOffline {
            if pinBadgeLayer.contents == nil {
                pinBadgeLayer.contents = MasonryStaticLayerAssets.pinOfflineBadge(scale: scale)
                pinBadgeLayer.contentsScale = scale
            }
            pinBadgeLayer.frame = CGRect(x: rightCursor - 18, y: 6, width: 18, height: 18)
            pinBadgeLayer.isHidden = false
        } else {
            pinBadgeLayer.isHidden = true
        }

        // Thumbnail image (synchronous zero-bridging CGImage fast path -> async off-main-thread fallback)
        guard !sameAsset || forceReloadImage || imageLayer.contents == nil else { return }
        loadTask?.cancel()
        loadTask = nil

        if let cached = loader?.cachedCGImage(for: asset.id, tier: .grid520) {
            clipLayer.backgroundColor = cardSurface.cgColor
            imageLayer.contents = cached
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
            imageLayer.contents = MasonryStaticLayerAssets.proceduralCardImage(for: asset, size: rect.size, isDark: isDark, scale: scale)
        } else {
            let tintHex = asset.dominantColors.first?.hex ?? (isDark ? "#262930" : "#EAE9E5")
            clipLayer.backgroundColor = NSColor.charkleHex(tintHex).withAlphaComponent(0.35).cgColor
            imageLayer.contents = nil
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
                self.clipLayer.backgroundColor = cardSurface.cgColor
            } else if self.imageLayer.contents == nil {
                self.imageLayer.contents = MasonryStaticLayerAssets.proceduralCardImage(
                    for: asset,
                    size: targetSize,
                    isDark: isDark,
                    scale: scale
                )
            }
            CATransaction.commit()
        }
    }

    func updateVisualStates(isSelected: Bool, isCut: Bool, isHiddenForHero: Bool, isDark: Bool, scale: CGFloat) {
        clipLayer.opacity = isHiddenForHero ? 0.0 : (isCut ? 0.52 : 1.0)
        if isSelected {
            borderLayer.borderColor = NSColor.controlAccentColor.cgColor
            borderLayer.borderWidth = 2.5
            layer.shadowOpacity = isDark ? 0.34 : 0.14
            layer.shadowRadius = 8
            layer.shadowOffset = CGSize(width: 0, height: 3)
            if selectedCheckLayer.contents == nil {
                selectedCheckLayer.contents = MasonryStaticLayerAssets.selectedCheckmarkBadge(scale: scale)
                selectedCheckLayer.contentsScale = scale
            }
            selectedCheckLayer.frame = CGRect(x: 6, y: 6, width: 22, height: 22)
            selectedCheckLayer.isHidden = false
        } else {
            let hairline = isDark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.08)
            borderLayer.borderColor = hairline.cgColor
            borderLayer.borderWidth = 0.75
            layer.shadowOpacity = isDark ? 0.22 : 0.06
            layer.shadowRadius = 3
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
            selectedCheckLayer.isHidden = true
        }

        if isCut {
            cutDashLayer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65).cgColor
            cutDashLayer.isHidden = false
        } else {
            cutDashLayer.isHidden = true
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
            if checkboxLayer.contents == nil {
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
}

// MARK: - Menu Action Closure Helper

private final class MasonryMenuActionTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func performAction() { handler() }
}

// MARK: - Native Flipped Layer-Backed Recycling Document View

private final class MasonryDocumentView: NSView, NSDraggingSource {
    /// `nonisolated` is mandatory under Swift 6: AppKit calls `isFlipped` concurrently via
    /// `dispatch_apply` during multi-item `beginDraggingSession(with:event:source:)`.
    override nonisolated var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
    private var isDarkMode: Bool = false
    private var reduceMotion: Bool = false
    private var callbacks = MasonryCallbacks()
    private var lastInteractiveZoomAt: CFAbsoluteTime = 0
    private var lastPublishedZoomWidth: CGFloat = 228
    private var lastAppliedJustifiedWidth: CGFloat = 214

    // Photos-style live optical pinch & ⌘+scroll zoom state
    private var isPinching: Bool = false
    private var pinchOpticalScale: CGFloat = 1.0
    private var pinchAnchorScreenPoint: CGPoint = .zero
    private var pinchAnchorAssetID: UUID?
    private var legacyPinchSettleWorkItem: DispatchWorkItem?
    private var scrollZoomAccumulator: CGFloat = 0
    private var lastScrollZoomStepAt: CFAbsoluteTime = 0

    private let spacing: CGFloat = 12
    private let horizontalPadding: CGFloat = 20
    private let tileOverscan: CGFloat = 520
    private let prefetchLookahead: CGFloat = 960

    private var layout: MasonryLayoutSnapshot = .empty
    private var lastLayoutWidth: CGFloat = 0
    private var activeTiles: [UUID: MasonryTileLayer] = [:]
    private var reusePool: [MasonryTileLayer] = []
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
        if window == nil {
            hoverMediaPreview.stop()
        } else {
            handleViewportFrameChanged()
        }
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
        activeQuickLookID: UUID?,
        isDarkMode: Bool,
        reduceMotion: Bool,
        callbacks: MasonryCallbacks
    ) {
        let hadAssetsBefore = !self.assets.isEmpty
        let assetsChanged = (self.assetsSignature != signature)
        let layoutModeChanged = (self.layoutMode != layoutMode)
        let columnWidthChanged = abs(self.targetColumnWidth - targetColumnWidth) >= 0.5
        let insetsChanged = abs(self.topInset - topInset) >= 0.5 || abs(self.bottomInset - bottomInset) >= 0.5
        let invalidationChanged = (self.loaderInvalidationVersion != loaderInvalidationVersion)
        let appearanceChanged = (self.isDarkMode != isDarkMode)
        let visualFlagsChanged = (self.selectedAssetIDs != selectedIDs)
            || (self.cutAssetIDs != cutIDs)
            || (self.activeQuickLookID != activeQuickLookID)

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
        self.activeQuickLookID = activeQuickLookID
        if activeQuickLookID != nil {
            hoverMediaPreview.stop()
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
        }

        let isSelfZoomEcho = !assetsChanged && !layoutModeChanged && !insetsChanged && columnWidthChanged
            && abs(targetColumnWidth - lastPublishedZoomWidth) < 1.0
            && (CFAbsoluteTimeGetCurrent() - lastInteractiveZoomAt) < 0.45

        if isSelfZoomEcho {
            if invalidationChanged || appearanceChanged {
                syncVisibleTiles(forceReconfigure: true, forceReloadImages: invalidationChanged)
            } else if visualFlagsChanged {
                updateVisibleTileStatesOnly()
            }
            return
        }

        if assetsChanged || layoutModeChanged || insetsChanged || layout.items.count != assets.count {
            let shouldAnimate = !reduceMotion && hadAssetsBefore && (layoutModeChanged || assetsChanged)
            if layoutModeChanged && hadAssetsBefore {
                recomputeLayoutAnchored(
                    anchorDocPoint: nil,
                    preferredAnchorAssetID: nil,
                    animate: shouldAnimate,
                    animationDuration: 0.28
                )
            } else {
                recomputeLayout(animate: shouldAnimate, animateNewTiles: shouldAnimate && assetsChanged)
            }
        } else if columnWidthChanged {
            // Only reflow when the discrete column count (Vertical) or quantized row-height stop (Justified)
            // actually changes — eliminates 120Hz slider-drag twitching and boundary oscillation.
            let width = activeContainerWidth()
            let densityChanged: Bool = switch layoutMode {
            case .verticalMasonry, .galleryFilmstrip:
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
                recomputeLayoutAnchored(
                    anchorDocPoint: nil,
                    preferredAnchorAssetID: nil,
                    animate: !reduceMotion && hadAssetsBefore,
                    animationDuration: 0.28
                )
            } else if invalidationChanged || appearanceChanged {
                syncVisibleTiles(forceReconfigure: true, forceReloadImages: invalidationChanged)
            } else if visualFlagsChanged {
                updateVisibleTileStatesOnly()
            }
        } else if invalidationChanged || appearanceChanged {
            syncVisibleTiles(forceReconfigure: true, forceReloadImages: invalidationChanged)
        } else if visualFlagsChanged {
            updateVisibleTileStatesOnly()
        }
    }

    // MARK: - macOS Photos-Style Optical Pinch & ⌘+Scroll Gallery Zoom

    private func activeContainerWidth() -> CGFloat {
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
        pinchAnchorAssetID = nil
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
        pinchAnchorAssetID = nil

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

    /// Picks the best visual anchor card to keep stationary during zoom/reflow:
    /// cursor card (during pinch/scroll) > visible selected card > viewport center card.
    private func pickAnchorItem(near docPoint: CGPoint?, preferredID: UUID?) -> MasonryItemFrame? {
        if let preferredID,
           let idx = assetIndexByID[preferredID],
           idx < layout.items.count,
           layout.items[idx].id == preferredID {
            let item = layout.items[idx]
            if item.rect.intersects(visibleRect.insetBy(dx: 0, dy: -tileOverscan)) {
                return item
            }
        }

        if let docPoint {
            if let hit = hitTestCard(at: docPoint),
               let idx = assetIndexByID[hit.asset.id],
               idx < layout.items.count {
                return layout.items[idx]
            }
            let candidates = layout.visibleItems(minY: max(0, visibleRect.minY - 60), maxY: visibleRect.maxY + 60)
            return candidates.min { a, b in
                let da = hypot(a.rect.midX - docPoint.x, a.rect.midY - docPoint.y)
                let db = hypot(b.rect.midX - docPoint.x, b.rect.midY - docPoint.y)
                return da < db
            }
        }

        let vis = visibleRect
        if !selectedAssetIDs.isEmpty {
            let visibleSelected = selectedAssetIDs.compactMap { id -> MasonryItemFrame? in
                guard let idx = assetIndexByID[id], idx < layout.items.count else { return nil }
                let item = layout.items[idx]
                return item.rect.intersects(vis) ? item : nil
            }
            if let bestSel = visibleSelected.min(by: {
                hypot($0.rect.midX - vis.midX, $0.rect.midY - vis.midY) < hypot($1.rect.midX - vis.midX, $1.rect.midY - vis.midY)
            }) {
                return bestSel
            }
        }

        let visCandidates = layout.visibleItems(minY: vis.minY, maxY: vis.maxY)
        return visCandidates.min { a, b in
            hypot(a.rect.midX - vis.midX, a.rect.midY - vis.midY) < hypot(b.rect.midX - vis.midX, b.rect.midY - vis.midY)
        }
    }

    /// Continuous trackpad two-finger pinch: 120fps GPU optical scaling around cursor with seamless
    /// optical-rebased handoff across column/density steps and critically damped settle on release.
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
            pinchAnchorScreenPoint = cursorScreen
            pinchAnchorAssetID = pickAnchorItem(near: cursorInDoc, preferredID: nil)?.id
            hoveredAssetID = nil
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
            for tile in activeTiles.values {
                tile.stripLayoutAnimations()
            }
            // Pick up live visual scale if interrupting an in-flight settle spring
            let liveScale = tilesContainerLayer.presentation()?.transform.m11 ?? 1.0
            pinchOpticalScale = max(0.84, min(1.18, liveScale))
            tilesContainerLayer.removeAnimation(forKey: "charkle.pinchSettle")
        } else {
            pinchAnchorScreenPoint = cursorScreen
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
        case .verticalMasonry, .galleryFilmstrip:
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
            let rebasedOptical = max(0.84, min(1.18, rawNext / max(0.4, stepRatio)))
            lastInteractiveZoomAt = CFAbsoluteTimeGetCurrent()
            lastPublishedZoomWidth = nextTargetWidth
            targetColumnWidth = nextTargetWidth
            pinchOpticalScale = rebasedOptical

            recomputeLayoutAnchored(
                anchorDocPoint: cursorInDoc,
                preferredAnchorAssetID: pinchAnchorAssetID,
                animate: !reduceMotion,
                animationDuration: 0.26,
                oldOpticalScale: oldOptical,
                newOpticalScale: rebasedOptical,
                opticalAnchorScreen: pinchAnchorScreenPoint
            )
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

    /// Cleanly steps density on ⌘+scroll wheel (mouse wheel or trackpad) with anchor-card scroll locking
    /// and cooldown hysteresis so rapid wheel notches glide smoothly instead of thrashing.
    func handleCommandScrollZoom(
        delta: CGFloat,
        isDiscreteWheel: Bool,
        anchorDocPoint: NSPoint
    ) {
        guard !assets.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if isDiscreteWheel {
            guard (now - lastScrollZoomStepAt) >= 0.12 else { return }
            let direction = delta > 0 ? 1 : -1
            commitSteppedZoom(direction: direction, anchorDocPoint: anchorDocPoint)
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
        commitSteppedZoom(direction: direction, anchorDocPoint: anchorDocPoint)
    }

    private func commitSteppedZoom(direction: Int, anchorDocPoint: NSPoint) {
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

        lastInteractiveZoomAt = CFAbsoluteTimeGetCurrent()
        lastPublishedZoomWidth = nextWidth
        targetColumnWidth = nextWidth

        recomputeLayoutAnchored(
            anchorDocPoint: anchorDocPoint,
            preferredAnchorAssetID: nil,
            animate: !reduceMotion,
            animationDuration: 0.28
        )
        callbacks.onZoomColumnWidth?(nextWidth)
    }

    func handleViewportFrameChanged() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        let width = floor(clipView.bounds.width)
        guard width > 120 else { return }
        if abs(width - lastLayoutWidth) >= 1 {
            cancelOpticalTransformImmediate()
            recomputeLayout(animate: false, reconfigureExisting: false)
        } else {
            updateDocumentHeight(clipHeight: clipView.bounds.height)
            syncVisibleTiles()
        }
    }

    func handleScrollBoundsChanged() {
        let visY = visibleRect.minY
        if abs(visY - lastScrollY) > 1 {
            scrollingDown = visY >= lastScrollY
            lastScrollY = visY
        }
        syncVisibleTiles()
    }

    func setLiveScrolling(_ scrolling: Bool) {
        isLiveScrolling = scrolling
        if scrolling {
            cancelOpticalTransformImmediate()
            hoveredAssetID = nil
            hoverOverlayLayer.hide()
            hoverMediaPreview.stop()
            for tile in activeTiles.values {
                tile.stripLayoutAnimations()
            }
        } else {
            refreshHoverForCurrentMouseLocation()
        }
    }

    /// Recomputes layout while locking the visual position of an anchor card (under cursor, selected, or viewport center)
    /// and compensating every tile's animation start rect for `ΔscrollY` + any optical pinch transform rebase.
    private func recomputeLayoutAnchored(
        anchorDocPoint: CGPoint?,
        preferredAnchorAssetID: UUID?,
        animate: Bool,
        animationDuration: CFTimeInterval = 0.28,
        oldOpticalScale: CGFloat = 1.0,
        newOpticalScale: CGFloat = 1.0,
        opticalAnchorScreen: CGPoint = .zero
    ) {
        let clipView = enclosingScrollView?.contentView
        let clipBounds = clipView?.bounds ?? bounds
        let width = activeContainerWidth()
        lastLayoutWidth = width

        let oldScrollY = clipBounds.origin.y
        let anchorItem = pickAnchorItem(near: anchorDocPoint, preferredID: preferredAnchorAssetID)
        let anchorID = anchorItem?.id
        let anchorOldScreenY: CGFloat? = anchorItem.map { item in
            let rawY = item.rect.midY - oldScrollY
            return opticalAnchorScreen.y + (rawY - opticalAnchorScreen.y) * oldOpticalScale
        }

        // Snapshot EVERY currently mounted tile's exact visual screen rect BEFORE layout/scroll mutates
        var oldScreenRects: [UUID: CGRect] = [:]
        if animate && !isLiveScrolling {
            oldScreenRects.reserveCapacity(activeTiles.count)
            for (id, tile) in activeTiles {
                let pres = tile.layer.presentation()?.frame ?? tile.frame
                let cx = opticalAnchorScreen.x + (pres.midX - opticalAnchorScreen.x) * oldOpticalScale
                let cy = opticalAnchorScreen.y + ((pres.midY - oldScrollY) - opticalAnchorScreen.y) * oldOpticalScale
                let w = pres.width * oldOpticalScale
                let h = pres.height * oldOpticalScale
                oldScreenRects[id] = CGRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h)
            }
        }

        let effectiveWidth = effectiveLayoutTargetWidth(for: targetColumnWidth, mode: layoutMode)
        if layoutMode == .horizontalJustified {
            lastAppliedJustifiedWidth = effectiveWidth
        }

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

        // Compute & apply exact anchor-locked scroll origin BEFORE mounting/animating visible tiles
        var newScrollY = oldScrollY
        if let clipView {
            let maxScrollY = max(0, layout.totalHeight - clipBounds.height)
            if oldScrollY <= 2 {
                newScrollY = 0
            } else if let anchorID,
                      let anchorOldScreenY,
                      let idx = assetIndexByID[anchorID],
                      idx < layout.items.count,
                      layout.items[idx].id == anchorID {
                let newAnchorRect = layout.items[idx].rect
                let targetRawY = opticalAnchorScreen.y + (anchorOldScreenY - opticalAnchorScreen.y) / max(0.1, newOpticalScale)
                newScrollY = max(0, min(maxScrollY, newAnchorRect.midY - targetRawY))
            } else {
                newScrollY = max(0, min(maxScrollY, oldScrollY))
            }

            if abs(newScrollY - oldScrollY) >= 0.5 {
                clipView.scroll(to: NSPoint(x: 0, y: newScrollY))
                enclosingScrollView?.reflectScrolledClipView(clipView)
                lastScrollY = newScrollY
            }
        }

        // Apply rebased optical scale around the updated scroll anchor before computing tile from-rects
        if abs(newOpticalScale - 1.0) > 0.0005 || abs(oldOpticalScale - 1.0) > 0.0005 {
            applyOpticalTransformImmediate(scale: newOpticalScale, anchorScreen: opticalAnchorScreen)
        }

        // Map each tile's old visual screen rect into the new post-scroll, post-optical document space
        var compensatedFromRects: [UUID: CGRect] = [:]
        if animate && !isLiveScrolling && !oldScreenRects.isEmpty {
            compensatedFromRects.reserveCapacity(oldScreenRects.count)
            let invS = 1.0 / max(0.1, newOpticalScale)
            for (id, screenRect) in oldScreenRects {
                let docMidX = opticalAnchorScreen.x + (screenRect.midX - opticalAnchorScreen.x) * invS
                let docMidY = (newScrollY + opticalAnchorScreen.y) + (screenRect.midY - opticalAnchorScreen.y) * invS
                let docW = screenRect.width * invS
                let docH = screenRect.height * invS
                compensatedFromRects[id] = CGRect(
                    x: docMidX - docW * 0.5,
                    y: docMidY - docH * 0.5,
                    width: docW,
                    height: docH
                )
            }
        }

        syncVisibleTiles(
            forceReconfigure: true,
            animateMoves: animate && !isLiveScrolling,
            animateNewTiles: animate && !isLiveScrolling,
            animationDuration: animationDuration,
            compensatedFromRects: compensatedFromRects.isEmpty ? nil : compensatedFromRects
        )
    }

    private func recomputeLayout(
        animate: Bool,
        animateNewTiles: Bool = false,
        animationDuration: CFTimeInterval = 0.26,
        reconfigureExisting: Bool = true
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
            animateMoves: animate && !isLiveScrolling,
            animateNewTiles: animateNewTiles && !isLiveScrolling,
            animationDuration: animationDuration,
            compensatedFromRects: oldRects
        )
    }

    private func updateDocumentHeight(clipHeight: CGFloat) {
        let targetWidth = max(240, lastLayoutWidth)
        let targetHeight = max(layout.totalHeight, max(1, clipHeight))
        if abs(frame.width - targetWidth) >= 0.5 || abs(frame.height - targetHeight) >= 0.5 {
            setFrameSize(NSSize(width: targetWidth, height: targetHeight))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Always mutate bounds+position (never frame) so any active optical pinch transform stays intact
        tilesContainerLayer.bounds = CGRect(origin: .zero, size: CGSize(width: targetWidth, height: targetHeight))
        tilesContainerLayer.position = .zero
        CATransaction.commit()
    }

    private func syncVisibleTiles(
        forceReconfigure: Bool = false,
        forceReloadImages: Bool = false,
        animateMoves: Bool = false,
        animateNewTiles: Bool = false,
        animationDuration: CFTimeInterval = 0.26,
        compensatedFromRects: [UUID: CGRect]? = nil
    ) {
        let vis = visibleRect
        guard vis.height > 0 || !assets.isEmpty else { return }
        let minY = max(0, vis.minY - tileOverscan)
        let maxY = vis.maxY + tileOverscan
        let visibleFrames = layout.visibleItems(minY: minY, maxY: maxY)

        var neededIDs = Set<UUID>()
        neededIDs.reserveCapacity(visibleFrames.count)
        for item in visibleFrames {
            neededIDs.insert(item.id)
        }

        // Far-jump crossfade threshold: cards wrapping wildly across columns softly dissolve in place
        // instead of flying diagonally over 10 other cards.
        let maxGlideDistance = max(layout.columnWidth * 1.55, 290)

        let scale = currentScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Recycle offscreen tiles back into the pool (zero allocations / zero deallocations)
        for (id, tile) in activeTiles where !neededIDs.contains(id) {
            tile.prepareForReuse()
            tile.layer.removeFromSuperlayer()
            activeTiles.removeValue(forKey: id)
            reusePool.append(tile)
        }

        // 2. Mount or update visible tiles
        for itemFrame in visibleFrames {
            guard itemFrame.index < assets.count else { continue }
            let asset = assets[itemFrame.index]
            guard asset.id == itemFrame.id else { continue }

            let isSelected = selectedAssetIDs.contains(asset.id)
            let isCut = cutAssetIDs.contains(asset.id)
            let isHidden = (activeQuickLookID == asset.id)

            if let existing = activeTiles[asset.id] {
                let rawPrevious = existing.frame
                let fromRect = compensatedFromRects?[asset.id] ?? rawPrevious
                if forceReconfigure {
                    existing.configure(
                        asset: asset,
                        frame: itemFrame.rect,
                        isSelected: isSelected,
                        isCut: isCut,
                        isHiddenForHero: isHidden,
                        isDark: isDarkMode,
                        scale: scale,
                        loader: loader,
                        forceReloadImage: forceReloadImages
                    )
                    if animateMoves && fromRect != itemFrame.rect {
                        let dist = hypot(itemFrame.rect.midX - fromRect.midX, itemFrame.rect.midY - fromRect.midY)
                        if dist <= maxGlideDistance {
                            existing.animateFrameTransition(from: fromRect, to: itemFrame.rect, duration: animationDuration)
                        } else {
                            existing.animateEnter(duration: min(0.22, animationDuration))
                        }
                    }
                } else if rawPrevious != itemFrame.rect {
                    existing.updateFrameOnly(itemFrame.rect)
                    if animateMoves && fromRect != itemFrame.rect {
                        let dist = hypot(itemFrame.rect.midX - fromRect.midX, itemFrame.rect.midY - fromRect.midY)
                        if dist <= maxGlideDistance {
                            existing.animateFrameTransition(from: fromRect, to: itemFrame.rect, duration: animationDuration)
                        } else {
                            existing.animateEnter(duration: min(0.22, animationDuration))
                        }
                    }
                }
            } else {
                let tile = reusePool.popLast() ?? MasonryTileLayer()
                tile.configure(
                    asset: asset,
                    frame: itemFrame.rect,
                    isSelected: isSelected,
                    isCut: isCut,
                    isHiddenForHero: isHidden,
                    isDark: isDarkMode,
                    scale: scale,
                    loader: loader,
                    forceReloadImage: forceReloadImages
                )
                tilesContainerLayer.addSublayer(tile.layer)
                if animateNewTiles {
                    tile.animateEnter(duration: min(0.22, animationDuration))
                }
                activeTiles[asset.id] = tile
            }
        }

        // Keep hover overlay & muted hover media preview aligned if still visible and not live-scrolling/pinching
        if !isLiveScrolling, !isPinching, let hoveredID = hoveredAssetID, let tile = activeTiles[hoveredID], let asset = tile.boundAsset {
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

        // 3. Background lookahead prefetching in scroll direction
        if let loader {
            let lookMin = scrollingDown ? maxY : max(0, minY - prefetchLookahead)
            let lookMax = scrollingDown ? (maxY + prefetchLookahead) : minY
            if lookMax > lookMin {
                let upcoming = layout.visibleItems(minY: lookMin, maxY: lookMax)
                if !upcoming.isEmpty {
                    loader.prefetch(assetIDs: Array(upcoming.prefix(16).map(\.id)), tier: .grid520)
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
        if !isLiveScrolling, let hoveredID = hoveredAssetID, let tile = activeTiles[hoveredID], let asset = tile.boundAsset {
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
        let candidates = layout.visibleItems(minY: point.y - 2, maxY: point.y + 2)
        for item in candidates where item.rect.contains(point) {
            if item.index < assets.count {
                let asset = assets[item.index]
                if asset.id == item.id {
                    return (asset, item.rect)
                }
            }
        }
        return nil
    }

    private func syncHoverMediaPreview(for asset: AssetRecord?, in frame: CGRect?, scale: CGFloat) {
        guard !isLiveScrolling,
              activeQuickLookID == nil,
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
        guard !isLiveScrolling, !isPinching, let window else {
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
        guard !isLiveScrolling, !isPinching else { return }
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
        selectedAssetIDs = newSelection
        updateVisibleTileStatesOnly()
        onSelectionChanged?(newSelection)
    }

    private func effectiveSelection(including id: UUID) -> [UUID] {
        if selectedAssetIDs.contains(id) {
            return Array(selectedAssetIDs)
        }
        return [id]
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
            autoscroll(with: event)
            let rect = CGRect(
                x: min(startPoint.x, point.x),
                y: min(startPoint.y, point.y),
                width: abs(point.x - startPoint.x),
                height: abs(point.y - startPoint.y)
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
    }

    override func mouseUp(with event: NSEvent) {
        switch pointerMode {
        case .none:
            break
        case .pendingCard(let asset, _, _, _):
            applyCardClick(asset: asset, modifiers: event.modifierFlags)
        case .marquee:
            if marqueeLayer.isHidden, !selectedAssetIDs.isEmpty {
                commitSelection([])
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
        if let str = pasteboard.string(forType: .string), CharkleDragIdentifiers.isInternalDrag(str) {
            return true
        }
        return false
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
        } else if let rawURLStr = pb.string(forType: .URL), let url = URL(string: rawURLStr),
                  url.scheme == "http" || url.scheme == "https" {
            inputs.append(.webURL(url, title: nil, notes: nil))
        } else if let png = pb.data(forType: .png) {
            inputs.append(.imageData(png, suggestedName: "Drop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            inputs.append(.imageData(png, suggestedName: "Drop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
        } else if let str = pb.string(forType: .string) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" {
                inputs.append(.webURL(url, title: nil, notes: nil))
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

        menu.addItem(makeMenuItem(title: "快速预览 (Space)", symbol: "eye") { [weak self] in
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
        case 49: // Space (fallback when used standalone outside MainWindowView)
            guard activeQuickLookID == nil else { return }
            if event.isARepeat { return }
            if let asset = assets.first(where: { selectedAssetIDs.contains($0.id) }) {
                callbacks.onOpenQuickLook(asset)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

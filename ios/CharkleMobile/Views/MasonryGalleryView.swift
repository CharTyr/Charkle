import CharkleCore
import QuartzCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Deterministic Virtualized Masonry Layout Snapshot & O(1) Cache

private struct VirtualizedMasonryItem: Identifiable {
    let id: UUID
    let index: Int
    let rect: CGRect
}

private struct RenderedMasonryCard: Identifiable {
    let id: UUID
    let asset: AssetRecord
    let midX: CGFloat
    let midY: CGFloat
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let opacity: Double
    let zIndex: Double
}

/// Coarse scroll bucket (`200pt` vertical stride) so 120Hz scrolling only triggers SwiftUI
/// virtualization diffing once every ~200pt instead of re-rendering the entire gallery on every pixel.
private struct GalleryViewportBucket: Equatable {
    let yBucket: Int
    let widthBucket: Int
    let heightBucket: Int

    static let bucketStride: CGFloat = 200

    init(minY: CGFloat, width: CGFloat, height: CGFloat) {
        self.yBucket = max(0, Int(floor(max(0, minY) / Self.bucketStride)))
        self.widthBucket = max(1, Int((width / 8.0).rounded()) * 8)
        self.heightBucket = max(1, Int((height / 16.0).rounded()) * 16)
    }

    var cullingRect: CGRect {
        CGRect(
            x: 0,
            y: CGFloat(yBucket) * Self.bucketStride,
            width: CGFloat(widthBucket),
            height: CGFloat(heightBucket) + Self.bucketStride
        )
    }
}

/// Non-reactive scroll offset storage for exact hit-testing in drag-to-multi-select without
/// causing SwiftUI view invalidations on every 120Hz scroll frame.
@MainActor
private final class MasonryScrollTracker {
    var liveScrollY: CGFloat = 0
}

private struct VirtualizedMasonrySnapshot {
    let colCount: Int
    let columnWidth: CGFloat
    let contentHeight: CGFloat
    let items: [VirtualizedMasonryItem]
    let rectByID: [UUID: CGRect]
    private let prefixMaxY: [CGFloat]

    static func build(
        assets: [AssetRecord],
        containerWidth: CGFloat,
        colCount: Int,
        spacing: CGFloat,
        horizontalPadding: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> VirtualizedMasonrySnapshot {
        let safeCols = max(1, colCount)
        let usableWidth = max(120, containerWidth - horizontalPadding * 2)
        let colWidth = (usableWidth - spacing * CGFloat(safeCols - 1)) / CGFloat(safeCols)
        var colHeights = Array(repeating: topInset, count: safeCols)
        var items: [VirtualizedMasonryItem] = []
        items.reserveCapacity(assets.count)
        var rectByID: [UUID: CGRect] = Dictionary(minimumCapacity: assets.count)
        var prefixMaxY: [CGFloat] = []
        prefixMaxY.reserveCapacity(assets.count)
        var runningMaxY: CGFloat = 0

        for (idx, asset) in assets.enumerated() {
            var bestCol = 0
            var minH = colHeights[0]
            if safeCols > 1 {
                for c in 1..<safeCols where colHeights[c] < minH - 0.5 {
                    minH = colHeights[c]
                    bestCol = c
                }
            }
            let ratio = MobileMasonryLayout.effectiveAspectRatio(for: asset)
            let cardHeight = max(44, (colWidth / ratio).rounded())
            let x = horizontalPadding + CGFloat(bestCol) * (colWidth + spacing)
            let y = colHeights[bestCol]
            let rect = CGRect(x: x, y: y, width: colWidth, height: cardHeight)
            items.append(VirtualizedMasonryItem(id: asset.id, index: idx, rect: rect))
            rectByID[asset.id] = rect
            if rect.maxY > runningMaxY {
                runningMaxY = rect.maxY
            }
            prefixMaxY.append(runningMaxY)
            colHeights[bestCol] = y + cardHeight + spacing
        }

        let totalHeight = max(topInset + bottomInset, (colHeights.max() ?? topInset) + bottomInset)
        return VirtualizedMasonrySnapshot(
            colCount: safeCols,
            columnWidth: colWidth,
            contentHeight: totalHeight,
            items: items,
            rectByID: rectByID,
            prefixMaxY: prefixMaxY
        )
    }

    /// O(log N + K) visible-item culling using monotonic `prefixMaxY` and shortest-column `minY` ordering.
    func visibleItems(in viewportRect: CGRect, overscan: CGFloat = 520) -> [VirtualizedMasonryItem] {
        guard !items.isEmpty else { return [] }
        let minY = viewportRect.minY - overscan
        let maxY = viewportRect.maxY + overscan
        guard maxY >= minY else { return [] }

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

        var result: [VirtualizedMasonryItem] = []
        result.reserveCapacity(48)
        for idx in lo..<items.count {
            let item = items[idx]
            if item.rect.minY > maxY + 1.0 {
                break
            }
            if item.rect.maxY >= minY {
                result.append(item)
            }
        }
        return result
    }

    func hitAssetID(at contentPoint: CGPoint, tolerance: CGFloat = 6) -> UUID? {
        let queryRect = CGRect(
            x: 0,
            y: contentPoint.y - tolerance,
            width: 1,
            height: tolerance * 2
        )
        for item in visibleItems(in: queryRect, overscan: 24)
        where item.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(contentPoint) {
            return item.id
        }
        return nil
    }

    func closestAssetID(to contentPoint: CGPoint) -> UUID? {
        if let exact = hitAssetID(at: contentPoint, tolerance: 8) {
            return exact
        }
        let localCandidates = visibleItems(
            in: CGRect(x: 0, y: max(0, contentPoint.y - 320), width: 1, height: 640),
            overscan: 160
        )
        let pool = localCandidates.isEmpty ? items : localCandidates
        var bestID: UUID?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for item in pool {
            let dx = item.rect.midX - contentPoint.x
            let dy = item.rect.midY - contentPoint.y
            let d = dx * dx + dy * dy
            if d < bestDist {
                bestDist = d
                bestID = item.id
            }
        }
        return bestID
    }
}

/// Caches deterministic masonry snapshots across column densities (`1...5` on iPhone, `2...7` on iPad)
/// so 120Hz scrolling and continuous pinch morphing perform O(1) lookups instead of rebuilding O(N) layouts per frame.
@MainActor
private final class MasonryLayoutCache {
    private struct QuickArrayStamp: Equatable {
        let pointer: UInt
        let count: Int
        let firstID: UUID?
        let midID: UUID?
        let lastID: UUID?
    }

    private struct AssetsFingerprint: Equatable {
        let count: Int
        let hashValue: Int

        init(assets: [AssetRecord]) {
            self.count = assets.count
            var hasher = Hasher()
            hasher.combine(assets.count)
            for asset in assets {
                hasher.combine(asset.id)
                hasher.combine(asset.pixelWidth)
                hasher.combine(asset.pixelHeight)
                hasher.combine(asset.mediaKind)
                hasher.combine(asset.richMetadata?.socialPost?.platform)
                hasher.combine(asset.fileName.lowercased().hasSuffix(".swatch"))
            }
            self.hashValue = hasher.finalize()
        }
    }

    private struct CacheKey: Hashable {
        let widthHalfPt: Int
        let colCount: Int
        let topInsetHalfPt: Int
        let bottomInsetHalfPt: Int
        let isCompact: Bool
    }

    private var lastAssetsVersion: UInt64?
    private var lastQuickStamp: QuickArrayStamp?
    private var cachedFingerprint: AssetsFingerprint?
    private var snapshots: [CacheKey: VirtualizedMasonrySnapshot] = [:]

    func snapshot(
        assets: [AssetRecord],
        assetsVersion: UInt64,
        containerWidth: CGFloat,
        colCount: Int,
        isCompact: Bool,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> VirtualizedMasonrySnapshot {
        let pointer: UInt = assets.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { UInt(bitPattern: $0) } ?? 0
        }
        let stamp = QuickArrayStamp(
            pointer: pointer,
            count: assets.count,
            firstID: assets.first?.id,
            midID: assets.isEmpty ? nil : assets[assets.count / 2].id,
            lastID: assets.last?.id
        )
        if assetsVersion != lastAssetsVersion || stamp != lastQuickStamp {
            lastAssetsVersion = assetsVersion
            lastQuickStamp = stamp
            let nextFingerprint = AssetsFingerprint(assets: assets)
            if nextFingerprint != cachedFingerprint {
                cachedFingerprint = nextFingerprint
                snapshots.removeAll(keepingCapacity: true)
            }
        }

        let key = CacheKey(
            widthHalfPt: Int((containerWidth * 2).rounded()),
            colCount: colCount,
            topInsetHalfPt: Int((topInset * 2).rounded()),
            bottomInsetHalfPt: Int((bottomInset * 2).rounded()),
            isCompact: isCompact
        )
        if let existing = snapshots[key] {
            return existing
        }

        let spacing = MobileMasonryLayout.adaptiveSpacing(for: colCount, isCompact: isCompact)
        let horizontalPadding: CGFloat = colCount >= 4 ? (colCount >= 5 ? 2 : 5) : (isCompact ? 8 : 16)
        let built = VirtualizedMasonrySnapshot.build(
            assets: assets,
            containerWidth: containerWidth,
            colCount: colCount,
            spacing: spacing,
            horizontalPadding: horizontalPadding,
            topInset: topInset,
            bottomInset: bottomInset
        )
        snapshots[key] = built
        return built
    }
}

// MARK: - 120Hz Continuous Photos-Style Pinch Zoom Controller & Native UIScrollView Bridge

private final class MasonrySettleDisplayLinkProxy: NSObject {
    weak var owner: MasonryPinchZoomController?

    @objc func handleTick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            owner?.stepSettleAnimation(link)
        }
    }
}

/// Drives true continuous ("无极放大缩小") 120Hz Photos-style pinch-to-zoom on iOS/iPadOS:
/// - Tracks continuous fractional column density (`1.0...5.0` iPhone / `2.0...7.0` iPad) 1:1 with finger spread
/// - Pins the exact photo card under the user's two fingers with 0pt viewport drift while interpolating cards
/// - Freezes the backing `UIScrollView` during morph/settle (preventing accidental pull-to-refresh or scroll fighting)
/// - Runs an interruptible 120Hz ease-out settle curve and performs an atomic 0pt handoff to native scrolling.
@Observable
@MainActor
private final class MasonryPinchZoomController {
    var isMorphActive: Bool = false
    var continuousCols: CGFloat = 2.0
    var rubberScale: CGFloat = 1.0
    var viewportAnchor: CGPoint = .zero
    var anchorAssetID: UUID? = nil
    var anchorNormV: CGFloat = 0.5
    var liveAnchorScreenY: CGFloat = 0
    var pinTopAtZero: Bool = false
    var frozenScrollY: CGFloat = 0
    var frozenTopInset: CGFloat = 0
    var frozenBottomInset: CGFloat = 0
    var frozenContentHeight: CGFloat = 0
    var activeBadgeLabel: String? = nil

    @ObservationIgnored weak var scrollView: UIScrollView?
    @ObservationIgnored private var minAllowedCols: Int = 1
    @ObservationIgnored private var maxAllowedCols: Int = 5
    @ObservationIgnored private var startCols: CGFloat = 2.0
    @ObservationIgnored private var startCentroidViewport: CGPoint = .zero
    @ObservationIgnored private var startAnchorScreenY: CGFloat = 0
    @ObservationIgnored private var lastHapticCols: Int = 2
    @ObservationIgnored private var badgeDismissTask: Task<Void, Never>?

    // Interruptible 120Hz settle spring state
    @ObservationIgnored private nonisolated(unsafe) var displayLink: CADisplayLink?
    @ObservationIgnored private var displayLinkProxy: MasonrySettleDisplayLinkProxy?
    @ObservationIgnored private var settleStartTime: CFTimeInterval = 0
    @ObservationIgnored private var settleDuration: CFTimeInterval = 0.22
    @ObservationIgnored private var settleFromCols: CGFloat = 2.0
    @ObservationIgnored private var settleToCols: Int = 2
    @ObservationIgnored private var settleFromRubber: CGFloat = 1.0
    @ObservationIgnored private var settleViewportHeight: CGFloat = 800
    @ObservationIgnored private var settleSnapshotProvider: ((Int) -> VirtualizedMasonrySnapshot)?
    @ObservationIgnored private var settleCommitHandler: ((Int, CGFloat) -> Void)?

    deinit {
        displayLink?.invalidate()
    }

    func attach(scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    var currentNormalizedScrollY: CGFloat? {
        guard let sv = scrollView else { return nil }
        return max(0, sv.contentOffset.y + sv.adjustedContentInset.top)
    }

    func beginPinch(
        centroidViewport: CGPoint,
        scrollY: CGFloat,
        currentCols: Int,
        minCols: Int,
        maxCols: Int,
        viewportSize: CGSize,
        topInset: CGFloat,
        bottomInset: CGFloat,
        snapshotProvider: (Int) -> VirtualizedMasonrySnapshot
    ) {
        minAllowedCols = minCols
        maxAllowedCols = maxCols

        // Interrupt any in-flight settle curve seamlessly from its exact current visual progress
        if isMorphActive {
            stopDisplayLink()
            startCols = continuousCols
            startCentroidViewport = centroidViewport
            startAnchorScreenY = liveAnchorScreenY
            viewportAnchor = centroidViewport
            return
        }

        let currentSnap = snapshotProvider(currentCols)
        let clampedScrollY = max(0, scrollY)
        let contentPoint = CGPoint(x: centroidViewport.x, y: clampedScrollY + centroidViewport.y)

        if let id = currentSnap.closestAssetID(to: contentPoint),
           let rect = currentSnap.rectByID[id] {
            anchorAssetID = id
            let rawNormV = (contentPoint.y - rect.minY) / max(1, rect.height)
            anchorNormV = max(0.15, min(0.85, rawNormV))
            startAnchorScreenY = (rect.minY + anchorNormV * rect.height) - clampedScrollY
            pinTopAtZero = (clampedScrollY <= 2 && rect.minY <= topInset + 8)
        } else {
            anchorAssetID = nil
            anchorNormV = 0.5
            startAnchorScreenY = centroidViewport.y
            pinTopAtZero = clampedScrollY <= 2
        }

        startCols = CGFloat(currentCols)
        continuousCols = startCols
        rubberScale = 1.0
        startCentroidViewport = centroidViewport
        liveAnchorScreenY = startAnchorScreenY
        viewportAnchor = centroidViewport
        frozenScrollY = clampedScrollY
        frozenTopInset = topInset
        frozenBottomInset = bottomInset
        frozenContentHeight = max(viewportSize.height, currentSnap.contentHeight)
        lastHapticCols = currentCols

        // Pre-warm all density snapshots once (~0.5ms) so every 120Hz frame is O(1)
        // and backing UIScrollView.contentSize already accommodates any target column handoff.
        var maxContentHeight = max(viewportSize.height, currentSnap.contentHeight)
        for cols in minCols...maxCols {
            let snap = snapshotProvider(cols)
            maxContentHeight = max(maxContentHeight, snap.contentHeight)
        }
        frozenContentHeight = maxContentHeight

        isMorphActive = true
    }

    func updatePinch(scale: CGFloat, centroidViewport: CGPoint, viewportHeight: CGFloat) {
        guard isMorphActive else { return }

        // Logarithmic symmetric sensitivity (~2.90 columns per 2x finger spread) so every
        // column transition (1↔2↔3↔4↔5 on iPhone, 2↔7 on iPad) responds immediately and evenly
        // to natural two-finger pinches without needing extreme finger travel.
        let safeScale = max(0.18, min(6.0, scale))
        let deltaCols = -CGFloat(log2(Double(safeScale))) * 2.90
        let rawCols = startCols + deltaCols

        if rawCols < CGFloat(minAllowedCols) {
            continuousCols = CGFloat(minAllowedCols)
            let excess = CGFloat(minAllowedCols) - rawCols
            rubberScale = 1.0 + CGFloat(tanh(Double(excess) * 0.9)) * 0.08
        } else if rawCols > CGFloat(maxAllowedCols) {
            continuousCols = CGFloat(maxAllowedCols)
            let excess = rawCols - CGFloat(maxAllowedCols)
            rubberScale = 1.0 - CGFloat(tanh(Double(excess) * 0.9)) * 0.06
        } else {
            continuousCols = rawCols
            rubberScale = 1.0
        }

        viewportAnchor = centroidViewport
        if !pinTopAtZero {
            let dy = centroidViewport.y - startCentroidViewport.y
            liveAnchorScreenY = max(
                frozenTopInset + 16,
                min(max(120, viewportHeight) - 24, startAnchorScreenY + dy * 0.65)
            )
        }

        let roundedCols = max(minAllowedCols, min(maxAllowedCols, Int(continuousCols.rounded())))
        if roundedCols != lastHapticCols {
            lastHapticCols = roundedCols
            MobileHaptics.selection()
            flashBadge("\(roundedCols) 列")
        }
    }

    func endPinch(
        velocity: CGFloat,
        viewportHeight: CGFloat,
        reduceMotion: Bool,
        snapshotProvider: @escaping (Int) -> VirtualizedMasonrySnapshot,
        onCommit: @escaping (Int, CGFloat) -> Void
    ) {
        guard isMorphActive else {
            scrollView?.isScrollEnabled = true
            return
        }

        let delta = continuousCols - startCols
        var biased = continuousCols
        if velocity > 0.18 && delta <= -0.10 {
            // Quick spread flick -> favor zooming in (fewer columns)
            biased -= 0.38
        } else if velocity < -0.18 && delta >= 0.10 {
            // Quick pinch-in flick -> favor zooming out (more columns)
            biased += 0.38
        } else if delta <= -0.30 {
            // Deliberate zoom-in past ~10% finger spread commits cleanly instead of snapping back
            biased -= 0.21
        } else if delta >= 0.30 {
            // Deliberate zoom-out past ~10% finger pinch commits cleanly instead of snapping back
            biased += 0.21
        }
        let targetCols = max(minAllowedCols, min(maxAllowedCols, Int(biased.rounded())))
        if targetCols != lastHapticCols {
            lastHapticCols = targetCols
            MobileHaptics.selection()
        }
        flashBadge("\(targetCols) 列")

        // Ensure backing UIScrollView contentSize accommodates targetCols BEFORE settle hands off
        let targetSnap = snapshotProvider(targetCols)
        frozenContentHeight = max(frozenContentHeight, max(viewportHeight, targetSnap.contentHeight))

        if reduceMotion
            || (abs(continuousCols - CGFloat(targetCols)) < 0.004 && abs(rubberScale - 1.0) < 0.004) {
            stopDisplayLink()
            continuousCols = CGFloat(targetCols)
            rubberScale = 1.0
            let finalScrollY = anchoredScrollY(for: targetSnap, viewportHeight: viewportHeight)
            onCommit(targetCols, finalScrollY)
            return
        }

        stopDisplayLink()
        settleStartTime = CACurrentMediaTime()
        settleDuration = 0.22
        settleFromCols = continuousCols
        settleToCols = targetCols
        settleFromRubber = rubberScale
        settleViewportHeight = viewportHeight
        settleSnapshotProvider = snapshotProvider
        settleCommitHandler = onCommit

        let proxy = MasonrySettleDisplayLinkProxy()
        proxy.owner = self
        displayLinkProxy = proxy

        let link = CADisplayLink(target: proxy, selector: #selector(MasonrySettleDisplayLinkProxy.handleTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stepSettleAnimation(_ link: CADisplayLink) {
        guard isMorphActive else {
            stopDisplayLink()
            return
        }
        let elapsed = max(0, CACurrentMediaTime() - settleStartTime)
        let rawProgress = min(1.0, elapsed / max(0.01, settleDuration))
        // Cubic ease-out matching DESIGN.md deceleration feel
        let eased = 1.0 - pow(1.0 - rawProgress, 3.0)

        continuousCols = settleFromCols + (CGFloat(settleToCols) - settleFromCols) * CGFloat(eased)
        rubberScale = settleFromRubber + (1.0 - settleFromRubber) * CGFloat(eased)

        if rawProgress >= 1.0 {
            let targetCols = settleToCols
            let height = settleViewportHeight
            let provider = settleSnapshotProvider
            let commit = settleCommitHandler
            stopDisplayLink()
            continuousCols = CGFloat(targetCols)
            rubberScale = 1.0
            if let provider, let commit {
                let targetSnap = provider(targetCols)
                let finalScrollY = anchoredScrollY(for: targetSnap, viewportHeight: height)
                commit(targetCols, finalScrollY)
            } else {
                cancelIfNeeded()
            }
        }
    }

    func completeCommit(scrollY: CGFloat) {
        stopDisplayLink()
        isMorphActive = false
        rubberScale = 1.0
        anchorAssetID = nil
        if let sv = scrollView {
            sv.isScrollEnabled = true
            let topInset = sv.adjustedContentInset.top
            let clampedOffsetY = max(-topInset, scrollY - topInset)
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: clampedOffsetY), animated: false)
        }
    }

    func cancelIfNeeded() {
        stopDisplayLink()
        if isMorphActive {
            isMorphActive = false
            rubberScale = 1.0
            anchorAssetID = nil
        }
        scrollView?.isScrollEnabled = true
    }

    func anchoredScrollY(for snapshot: VirtualizedMasonrySnapshot, viewportHeight: CGFloat) -> CGFloat {
        let maxY = max(0, snapshot.contentHeight - max(200, viewportHeight))
        if pinTopAtZero {
            return 0
        }
        guard let anchorAssetID, let rect = snapshot.rectByID[anchorAssetID] else {
            return max(0, min(maxY, frozenScrollY))
        }
        let anchorPointY = rect.minY + anchorNormV * rect.height
        return max(0, min(maxY, anchorPointY - liveAnchorScreenY))
    }

    func interpolatedCards(
        assets: [AssetRecord],
        viewportSize: CGSize,
        snapshotProvider: (Int) -> VirtualizedMasonrySnapshot
    ) -> [RenderedMasonryCard] {
        let lowCols = max(minAllowedCols, min(maxAllowedCols, Int(floor(continuousCols))))
        let highCols = max(minAllowedCols, min(maxAllowedCols, Int(ceil(continuousCols))))
        let t = max(0, min(1, continuousCols - CGFloat(lowCols)))

        let snapLow = snapshotProvider(lowCols)
        let snapHigh = (highCols == lowCols) ? snapLow : snapshotProvider(highCols)

        let scrollLow = anchoredScrollY(for: snapLow, viewportHeight: viewportSize.height)
        let scrollHigh = (highCols == lowCols)
            ? scrollLow
            : anchoredScrollY(for: snapHigh, viewportHeight: viewportSize.height)

        let lowRadius = MobileMasonryLayout.adaptiveCornerRadius(for: lowCols)
        let highRadius = MobileMasonryLayout.adaptiveCornerRadius(for: highCols)
        let blendedRadius = lowRadius + (highRadius - lowRadius) * t

        let visibleLow = snapLow.visibleItems(
            in: CGRect(x: 0, y: scrollLow, width: viewportSize.width, height: viewportSize.height),
            overscan: 260
        )
        var seen = Set<UUID>()
        seen.reserveCapacity(visibleLow.count * 2)
        var unionAssets: [AssetRecord] = []
        unionAssets.reserveCapacity(visibleLow.count * 2)
        func resolveLiveAsset(_ item: VirtualizedMasonryItem) -> AssetRecord? {
            if item.index >= 0 && item.index < assets.count && assets[item.index].id == item.id {
                return assets[item.index]
            }
            return assets.first(where: { $0.id == item.id })
        }
        for item in visibleLow where seen.insert(item.id).inserted {
            if let live = resolveLiveAsset(item) {
                unionAssets.append(live)
            }
        }
        if highCols != lowCols {
            let visibleHigh = snapHigh.visibleItems(
                in: CGRect(x: 0, y: scrollHigh, width: viewportSize.width, height: viewportSize.height),
                overscan: 260
            )
            for item in visibleHigh where seen.insert(item.id).inserted {
                if let live = resolveLiveAsset(item) {
                    unionAssets.append(live)
                }
            }
        }

        let hasRubber = abs(rubberScale - 1.0) > 0.0005
        let wrapThreshold = viewportSize.width * 0.55

        var output: [RenderedMasonryCard] = []
        output.reserveCapacity(unionAssets.count)

        for asset in unionAssets {
            guard let rLow = snapLow.rectByID[asset.id],
                  let rHigh = snapHigh.rectByID[asset.id] else {
                continue
            }

            let sLow = CGRect(x: rLow.minX, y: rLow.minY - scrollLow, width: rLow.width, height: rLow.height)
            let sHigh = CGRect(x: rHigh.minX, y: rHigh.minY - scrollHigh, width: rHigh.width, height: rHigh.height)

            let rawMidX = sLow.midX + (sHigh.midX - sLow.midX) * t
            let rawMidY = sLow.midY + (sHigh.midY - sLow.midY) * t
            let rawW = sLow.width + (sHigh.width - sLow.width) * t
            let rawH = sLow.height + (sHigh.height - sLow.height) * t

            let finalMidX: CGFloat
            let finalMidYScreen: CGFloat
            let finalW: CGFloat
            let finalH: CGFloat
            if hasRubber {
                finalMidX = viewportAnchor.x + (rawMidX - viewportAnchor.x) * rubberScale
                finalMidYScreen = viewportAnchor.y + (rawMidY - viewportAnchor.y) * rubberScale
                finalW = rawW * rubberScale
                finalH = rawH * rubberScale
            } else {
                finalMidX = rawMidX
                finalMidYScreen = rawMidY
                finalW = rawW
                finalH = rawH
            }

            let isAnchor = (asset.id == anchorAssetID)
            let opacity: Double
            if !isAnchor && highCols != lowCols {
                let travel = hypot(sHigh.midX - sLow.midX, sHigh.midY - sLow.midY)
                opacity = travel > wrapThreshold ? (1.0 - 0.30 * sin(Double(t) * .pi)) : 1.0
            } else {
                opacity = 1.0
            }

            output.append(
                RenderedMasonryCard(
                    id: asset.id,
                    asset: asset,
                    midX: finalMidX,
                    midY: frozenScrollY + finalMidYScreen,
                    width: max(20, finalW),
                    height: max(20, finalH),
                    cornerRadius: blendedRadius,
                    opacity: opacity,
                    zIndex: isAnchor ? 10 : 0
                )
            )
        }

        return output
    }

    private func flashBadge(_ text: String) {
        badgeDismissTask?.cancel()
        withAnimation(MobileMotion.enterSm) {
            activeBadgeLabel = text
        }
        badgeDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            withAnimation(MobileMotion.exitSm) {
                activeBadgeLabel = nil
            }
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        settleSnapshotProvider = nil
        settleCommitHandler = nil
    }
}

/// Attaches a native `UIPinchGestureRecognizer` directly to the backing `UIScrollView` so two-finger
/// continuous gallery zooming cancels accidental pull-to-refresh/pan cleanly without SwiftUI `.scrollDisabled`
/// view-tree churn, and exposes direct `UIScrollView.setContentOffset` access for 0pt handoff.
private struct GalleryScrollPinchBridge: UIViewRepresentable {
    let isEnabled: Bool
    let onAttachScrollView: (UIScrollView) -> Void
    let onPinchBegan: (_ centroidViewport: CGPoint, _ normalizedScrollY: CGFloat) -> Void
    let onPinchChanged: (_ scale: CGFloat, _ centroidViewport: CGPoint) -> Void
    let onPinchEnded: (_ velocity: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.attachIfNeeded(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        let coord = context.coordinator
        coord.isEnabled = isEnabled
        coord.onAttachScrollView = onAttachScrollView
        coord.onPinchBegan = onPinchBegan
        coord.onPinchChanged = onPinchChanged
        coord.onPinchEnded = onPinchEnded
        coord.attachIfNeeded(from: uiView)
    }

    static func dismantleUIView(_ uiView: BridgeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class BridgeView: UIView {
        var onWindowChange: (() -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onWindowChange?()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onWindowChange?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool = true
        var onAttachScrollView: ((UIScrollView) -> Void)?
        var onPinchBegan: ((CGPoint, CGFloat) -> Void)?
        var onPinchChanged: ((CGFloat, CGPoint) -> Void)?
        var onPinchEnded: ((CGFloat) -> Void)?

        private weak var attachedScrollView: UIScrollView?
        private var pinchRecognizer: UIPinchGestureRecognizer?
        private var lastValidCentroidViewport: CGPoint = .zero

        func attachIfNeeded(from view: UIView) {
            var cursor = view.superview
            var found: UIScrollView?
            while let current = cursor {
                if let sv = current as? UIScrollView {
                    found = sv
                    break
                }
                cursor = current.superview
            }
            guard let scrollView = found else { return }
            if attachedScrollView === scrollView {
                onAttachScrollView?(scrollView)
                return
            }
            detach()
            attachedScrollView = scrollView
            scrollView.isMultipleTouchEnabled = true
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            pinch.cancelsTouchesInView = true
            pinch.delaysTouchesBegan = false
            pinch.delaysTouchesEnded = false
            scrollView.addGestureRecognizer(pinch)
            pinchRecognizer = pinch
            onAttachScrollView?(scrollView)
        }

        func detach() {
            if let sv = attachedScrollView, let pinch = pinchRecognizer {
                sv.removeGestureRecognizer(pinch)
                sv.isScrollEnabled = true
            }
            pinchRecognizer = nil
            attachedScrollView = nil
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Allow simultaneous recognition alongside UIScrollView pan, SwiftUI's internal
            // UIKitGestureRecognizer (card buttons / drag modifiers), and UIContextMenuInteraction
            // long-presses so two-finger pinch ALWAYS enters `.began` reliably on first try.
            if let otherPinch = otherGestureRecognizer as? UIPinchGestureRecognizer {
                return otherPinch === attachedScrollView?.pinchGestureRecognizer
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        // MARK: - Action

        private func viewportCentroid(of recognizer: UIPinchGestureRecognizer, in scrollView: UIScrollView) -> CGPoint {
            let raw = recognizer.location(in: scrollView)
            let topInset = scrollView.adjustedContentInset.top
            let visibleHeight = max(120, scrollView.bounds.height)
            return CGPoint(
                x: max(0, min(scrollView.bounds.width, raw.x - scrollView.bounds.minX)),
                y: max(0, min(visibleHeight, raw.y - scrollView.bounds.minY - topInset))
            )
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView = attachedScrollView else { return }
            let topInset = scrollView.adjustedContentInset.top

            switch recognizer.state {
            case .began:
                // Immediately halt any coasting deceleration or accidental scroll/pull-to-refresh pan
                if scrollView.panGestureRecognizer.state == .began
                    || scrollView.panGestureRecognizer.state == .changed {
                    scrollView.panGestureRecognizer.isEnabled = false
                    scrollView.panGestureRecognizer.isEnabled = true
                }
                let clampedStartY = max(-topInset, scrollView.contentOffset.y)
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: clampedStartY),
                    animated: false
                )
                scrollView.isScrollEnabled = false

                let centroid = viewportCentroid(of: recognizer, in: scrollView)
                lastValidCentroidViewport = centroid
                let normalizedScrollY = max(0, scrollView.contentOffset.y + topInset)
                onPinchBegan?(centroid, normalizedScrollY)

            case .changed:
                if recognizer.numberOfTouches >= 2 {
                    lastValidCentroidViewport = viewportCentroid(of: recognizer, in: scrollView)
                }
                onPinchChanged?(recognizer.scale, lastValidCentroidViewport)

            case .ended, .cancelled, .failed:
                let velocity = recognizer.state == .ended ? recognizer.velocity : 0
                onPinchEnded?(velocity)

            default:
                break
            }
        }
    }
}

/// High-density Gallery-First vertical masonry waterfall modeled on iOS Photos & `DESIGN.md`:
/// - O(1)-cached deterministic virtualization (`ScrollPosition` + `.onScrollGeometryChange`) so
///   1,900+ assets scroll smoothly at 120Hz with zero column-collapse glitches.
/// - True continuous ("无极放大缩小") 120Hz Photos-style pinch-to-zoom anchored directly on the photo
///   under the user's two fingers across `1...5` (iPhone) / `2...7` (iPad) columns with zero twitch/blank frames.
/// - Native iOS 26+ Liquid Glass (`GlassEffectContainer` + `.glassEffect`) on top-right controls & floating docks.
/// - Continuous horizontal/diagonal drag-to-multi-select sweep in `选取` mode.
/// - Exact reveal-in-library scroll & cobalt spotlight pulse when locating an asset from a Moodboard.
/// - 1:1 desktop-parity long-press context menu.
struct MasonryGalleryView: View {
    @Bindable var store: MobileAppStore
    var assetsOverride: [AssetRecord]? = nil
    let isCompact: Bool
    let showPhotosFloatingHeader: Bool
    var isTabActive: Bool = true
    var focusSearchTrigger: UInt64 = 0
    let zoomNamespace: Namespace.ID
    let zoomOrigin: PreviewZoomOrigin
    let onOpenAsset: (AssetRecord) -> Void
    let onFindSimilar: (AssetRecord) -> Void
    let onOpenCapture: () -> Void
    let onOpenSyncSettings: () -> Void
    let onOpenFolders: (() -> Void)?

    private var displayedAssets: [AssetRecord] {
        assetsOverride ?? store.assets
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFilterSheetPresented = false
    @State private var isBatchFolderSheetPresented = false
    @State private var singleMoveAsset: AssetRecord?
    @State private var isBatchBoardSheetPresented = false
    @State private var confirmPermanentDelete = false
    @State private var singleDeleteAssetID: UUID?
    @State private var shareAssetURL: URL?

    // Deterministic Scroll + Coarse Viewport Bucketing + O(1) Layout Snapshot Cache
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var viewportBucket = GalleryViewportBucket(minY: 0, width: 390, height: 844)
    @State private var scrollTracker = MasonryScrollTracker()
    @State private var lastKnownWidth: CGFloat = 390
    @State private var scrollContainerHeight: CGFloat = 0
    @State private var lastKnownContentHeight: CGFloat = 600
    @State private var layoutCache = MasonryLayoutCache()

    // 120Hz Continuous Photos-style pinch-to-zoom controller
    @State private var pinchController = MasonryPinchZoomController()

    // Apple Photos-style drag-to-multi-select state
    private enum DragDecision {
        case scroll
        case sweepSelect
    }
    @State private var dragDecision: DragDecision? = nil
    @State private var dragStartAssetID: UUID? = nil
    @State private var dragAddsSelection: Bool = true
    @State private var preDragSelection: Set<UUID> = []
    @State private var lastSweptAssetID: UUID? = nil

    private var isActivelySweepingSelection: Bool {
        store.isMultiSelectMode && dragDecision == .sweepSelect
    }

    var body: some View {
        ZStack(alignment: .top) {
            MobileTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            if displayedAssets.isEmpty && store.hasCompletedInitialLoad && !store.isLoadingLibrary && !store.isReloadingAssets {
                VStack(spacing: 0) {
                    if showPhotosFloatingHeader {
                        photosFloatingHeader
                    } else {
                        FilterBarView(
                            store: store,
                            isCompact: isCompact,
                            focusSearchTrigger: focusSearchTrigger,
                            onOpenFilterSheet: { isFilterSheetPresented = true }
                        )
                    }
                    emptyStateView
                }
            } else {
                GeometryReader { proxy in
                    let colCount = MobileMasonryLayout.resolvedColumnCount(
                        for: proxy.size.width,
                        isCompact: isCompact,
                        override: store.columnCountOverride
                    )
                    let cardCornerRadius = MobileMasonryLayout.adaptiveCornerRadius(for: colCount)
                    let horizontalPadding: CGFloat = colCount >= 4 ? (colCount >= 5 ? 2 : 5) : (isCompact ? 8 : 16)
                    let topClearance: CGFloat = showPhotosFloatingHeader
                        ? (store.hasActiveFilters ? 116 : 74)
                        : (colCount >= 5 ? 4 : 8)
                    let bannerExtra: CGFloat = (store.syncStatus.isSyncing && store.syncStatus.progressFraction != nil) ? 62 : 0
                    let liveTopInset = topClearance + bannerExtra
                    let liveBottomInset: CGFloat = store.isMultiSelectMode ? 120 : 54
                    let isMorphing = isTabActive && pinchController.isMorphActive
                    let activeTopInset = isMorphing ? pinchController.frozenTopInset : liveTopInset
                    let activeBottomInset = isMorphing ? pinchController.frozenBottomInset : liveBottomInset
                    let effectiveViewportHeight = max(
                        200,
                        scrollContainerHeight > 40 ? scrollContainerHeight : proxy.size.height
                    )
                    let effectiveViewportSize = CGSize(width: proxy.size.width, height: effectiveViewportHeight)
                    let assetsNow = displayedAssets
                    let assetsVersionNow = store.assetsMutationVersion

                    let snapshot: VirtualizedMasonrySnapshot? = isTabActive
                        ? layoutCache.snapshot(
                            assets: assetsNow,
                            assetsVersion: assetsVersionNow,
                            containerWidth: proxy.size.width,
                            colCount: colCount,
                            isCompact: isCompact,
                            topInset: activeTopInset,
                            bottomInset: activeBottomInset
                        )
                        : nil

                    let renderedCards: [RenderedMasonryCard] = {
                        guard isTabActive, let snapshot else { return [] }
                        if isMorphing {
                            return pinchController.interpolatedCards(
                                assets: assetsNow,
                                viewportSize: effectiveViewportSize,
                                snapshotProvider: { cols in
                                    layoutCache.snapshot(
                                        assets: assetsNow,
                                        assetsVersion: assetsVersionNow,
                                        containerWidth: proxy.size.width,
                                        colCount: cols,
                                        isCompact: isCompact,
                                        topInset: activeTopInset,
                                        bottomInset: activeBottomInset
                                    )
                                }
                            )
                        }
                        let maxCullMinY = max(0, snapshot.contentHeight - effectiveViewportHeight)
                        let clampedCullMinY = min(viewportBucket.cullingRect.minY, maxCullMinY)
                        let visible = snapshot.visibleItems(
                            in: CGRect(
                                x: 0,
                                y: clampedCullMinY,
                                width: proxy.size.width,
                                height: max(effectiveViewportHeight + GalleryViewportBucket.bucketStride, viewportBucket.cullingRect.height)
                            ),
                            overscan: 760
                        )
                        return visible.compactMap { item in
                            let liveAsset: AssetRecord?
                            if item.index >= 0 && item.index < assetsNow.count && assetsNow[item.index].id == item.id {
                                liveAsset = assetsNow[item.index]
                            } else {
                                liveAsset = assetsNow.first(where: { $0.id == item.id })
                            }
                            guard let liveAsset else { return nil }
                            return RenderedMasonryCard(
                                id: item.id,
                                asset: liveAsset,
                                midX: item.rect.midX,
                                midY: item.rect.midY,
                                width: item.rect.width,
                                height: item.rect.height,
                                cornerRadius: cardCornerRadius,
                                opacity: 1.0,
                                zIndex: 0
                            )
                        }
                    }()

                    let resolvedContentHeight: CGFloat = {
                        if !isTabActive {
                            return max(effectiveViewportHeight, lastKnownContentHeight)
                        }
                        if isMorphing {
                            return max(effectiveViewportHeight, pinchController.frozenContentHeight)
                        }
                        return max(effectiveViewportHeight, snapshot?.contentHeight ?? lastKnownContentHeight)
                    }()
                    let denseCardsFlag = isMorphing
                        ? (pinchController.continuousCols >= 3.6)
                        : (colCount >= 4)

                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            if !showPhotosFloatingHeader {
                                FilterBarView(
                                    store: store,
                                    isCompact: isCompact,
                                    focusSearchTrigger: focusSearchTrigger,
                                    onOpenFilterSheet: { isFilterSheetPresented = true }
                                )
                            }

                            ScrollView {
                                ZStack(alignment: .topLeading) {
                                    // Full virtualized content height anchor
                                    Color.clear
                                        .frame(
                                            width: proxy.size.width,
                                            height: resolvedContentHeight
                                        )

                                    // Optional top status banner (sync progress)
                                    if bannerExtra > 0 && !isMorphing {
                                        VStack(spacing: 8) {
                                            if store.syncStatus.isSyncing, let fraction = store.syncStatus.progressFraction {
                                                syncProgressBanner(fraction: fraction)
                                            }
                                        }
                                        .padding(.horizontal, max(10, horizontalPadding))
                                        .offset(y: topClearance)
                                    }

                                    // Single unified ForEach preserves GalleryCardView identity & decoded thumbnails
                                    // continuously across normal scroll -> 120Hz pinch morph -> settle -> scroll!
                                    ForEach(renderedCards) { card in
                                        GalleryCardView(
                                            asset: card.asset,
                                            store: store,
                                            zoomNamespace: zoomNamespace,
                                            zoomOrigin: zoomOrigin,
                                            cornerRadius: card.cornerRadius,
                                            isDenseOverview: denseCardsFlag,
                                            isMultiSelect: store.isMultiSelectMode,
                                            isSelected: store.selectedAssetIDs.contains(card.id),
                                            isHighlighted: store.highlightedAssetID == card.id,
                                            isMorphing: isMorphing,
                                            onTap: {
                                                guard !isMorphing else { return }
                                                MobileKeyboard.dismiss()
                                                if store.isMultiSelectMode {
                                                    toggleSelection(card.id)
                                                } else {
                                                    onOpenAsset(card.asset)
                                                }
                                            },
                                            onFindSimilar: { onFindSimilar(card.asset) },
                                            onShareOriginal: {
                                                Task { await shareAsset(card.asset) }
                                            },
                                            onRequestPermanentDelete: {
                                                singleDeleteAssetID = card.id
                                            },
                                            onSelectMultiple: {
                                                store.isMultiSelectMode = true
                                                store.selectedAssetIDs.insert(card.id)
                                            },
                                            onOpenFolderPicker: {
                                                singleMoveAsset = card.asset
                                            }
                                        )
                                        .frame(width: card.width, height: card.height)
                                        .position(x: card.midX, y: card.midY)
                                        .opacity(card.opacity)
                                        .zIndex(card.zIndex)
                                    }
                                }
                                .background(
                                    GalleryScrollPinchBridge(
                                        isEnabled: isTabActive && !displayedAssets.isEmpty && !isActivelySweepingSelection,
                                        onAttachScrollView: { scrollView in
                                            pinchController.attach(scrollView: scrollView)
                                        },
                                        onPinchBegan: { centroidViewport, normalizedScrollY in
                                            MobileKeyboard.dismiss()
                                            let minCols = isCompact ? 1 : 2
                                            let maxCols = isCompact ? 5 : 7
                                            let widthNow = proxy.size.width
                                            let sizeNow = effectiveViewportSize
                                            let capturedAssets = displayedAssets
                                            let capturedVersion = store.assetsMutationVersion
                                            let compactFlag = isCompact
                                            pinchController.beginPinch(
                                                centroidViewport: centroidViewport,
                                                scrollY: normalizedScrollY,
                                                currentCols: colCount,
                                                minCols: minCols,
                                                maxCols: maxCols,
                                                viewportSize: sizeNow,
                                                topInset: liveTopInset,
                                                bottomInset: liveBottomInset,
                                                snapshotProvider: { cols in
                                                    layoutCache.snapshot(
                                                        assets: capturedAssets,
                                                        assetsVersion: capturedVersion,
                                                        containerWidth: widthNow,
                                                        colCount: cols,
                                                        isCompact: compactFlag,
                                                        topInset: liveTopInset,
                                                        bottomInset: liveBottomInset
                                                    )
                                                }
                                            )
                                        },
                                        onPinchChanged: { scale, centroidViewport in
                                            pinchController.updatePinch(
                                                scale: scale,
                                                centroidViewport: centroidViewport,
                                                viewportHeight: effectiveViewportHeight
                                            )
                                        },
                                        onPinchEnded: { velocity in
                                            let widthNow = proxy.size.width
                                            let heightNow = effectiveViewportHeight
                                            let capturedAssets = displayedAssets
                                            let capturedVersion = store.assetsMutationVersion
                                            let compactFlag = isCompact
                                            let morphTop = pinchController.frozenTopInset
                                            let morphBottom = pinchController.frozenBottomInset
                                            pinchController.endPinch(
                                                velocity: velocity,
                                                viewportHeight: heightNow,
                                                reduceMotion: reduceMotion,
                                                snapshotProvider: { cols in
                                                    layoutCache.snapshot(
                                                        assets: capturedAssets,
                                                        assetsVersion: capturedVersion,
                                                        containerWidth: widthNow,
                                                        colCount: cols,
                                                        isCompact: compactFlag,
                                                        topInset: morphTop,
                                                        bottomInset: morphBottom
                                                    )
                                                },
                                                onCommit: { targetCols, _ in
                                                    let finalTop = showPhotosFloatingHeader
                                                        ? (store.hasActiveFilters ? 116 : 74)
                                                        : (targetCols >= 5 ? 4 : 8)
                                                    let finalBanner: CGFloat = (store.syncStatus.isSyncing && store.syncStatus.progressFraction != nil) ? 62 : 0
                                                    let finalBottom: CGFloat = store.isMultiSelectMode ? 120 : 54
                                                    let finalSnap = layoutCache.snapshot(
                                                        assets: displayedAssets,
                                                        assetsVersion: store.assetsMutationVersion,
                                                        containerWidth: widthNow,
                                                        colCount: targetCols,
                                                        isCompact: compactFlag,
                                                        topInset: CGFloat(finalTop) + finalBanner,
                                                        bottomInset: finalBottom
                                                    )
                                                    let exactFinalScrollY = pinchController.anchoredScrollY(
                                                        for: finalSnap,
                                                        viewportHeight: heightNow
                                                    )
                                                    var tx = Transaction()
                                                    tx.disablesAnimations = true
                                                    CATransaction.begin()
                                                    CATransaction.setDisableActions(true)
                                                    withTransaction(tx) {
                                                        store.columnCountOverride = targetCols
                                                        scrollTracker.liveScrollY = exactFinalScrollY
                                                        viewportBucket = GalleryViewportBucket(
                                                            minY: exactFinalScrollY,
                                                            width: widthNow,
                                                            height: heightNow
                                                        )
                                                        pinchController.completeCommit(scrollY: exactFinalScrollY)
                                                        scrollPosition.scrollTo(y: exactFinalScrollY)
                                                    }
                                                    CATransaction.commit()
                                                }
                                            )
                                        }
                                    )
                                )
                            }
                            .charkleDismissKeyboardOnScroll()
                            .scrollPosition($scrollPosition)
                            .onScrollGeometryChange(for: GalleryViewportBucket.self) { geo in
                                GalleryViewportBucket(
                                    minY: geo.visibleRect.minY,
                                    width: geo.containerSize.width,
                                    height: geo.containerSize.height
                                )
                            } action: { _, nextBucket in
                                let measuredHeight = CGFloat(nextBucket.heightBucket)
                                if measuredHeight > 100 && abs(measuredHeight - scrollContainerHeight) > 1 {
                                    scrollContainerHeight = measuredHeight
                                }
                                if !pinchController.isMorphActive && viewportBucket != nextBucket {
                                    viewportBucket = nextBucket
                                    scrollTracker.liveScrollY = CGFloat(nextBucket.yBucket) * GalleryViewportBucket.bucketStride
                                    if let snapshot {
                                        prefetchAroundBucket(nextBucket, snapshot: snapshot)
                                    }
                                }
                            }
                            .charkleScrollEdgeSoft(for: showPhotosFloatingHeader ? [.top, .bottom] : .bottom)
                            .coordinateSpace(name: "galleryViewport")
                            .scrollDisabled(isActivelySweepingSelection)
                            .refreshable {
                                if store.hasConnectedCloudBackend {
                                    await store.syncNow(quiet: false)
                                } else {
                                    await store.reloadAll()
                                }
                            }
                            .simultaneousGesture(
                                dragMultiSelectGesture(snapshot: snapshot),
                                including: store.isMultiSelectMode ? .all : .subviews
                            )
                        }

                        if showPhotosFloatingHeader {
                            photosFloatingHeader
                        }

                        if let badgeLabel = pinchController.activeBadgeLabel {
                            Text(badgeLabel)
                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .charkleFloatingCapsule(interactive: false)
                                .padding(.top, showPhotosFloatingHeader ? 84 : 12)
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                                .allowsHitTesting(false)
                        }
                    }
                    .onAppear {
                        lastKnownWidth = proxy.size.width
                        if let snapshot {
                            lastKnownContentHeight = snapshot.contentHeight
                            if viewportBucket.cullingRect.minY > snapshot.contentHeight {
                                resetViewportToTop(width: proxy.size.width, height: effectiveViewportHeight)
                            }
                            performPendingRevealIfNeeded(snapshot: snapshot, viewportHeight: effectiveViewportHeight)
                            prefetchAroundBucket(viewportBucket, snapshot: snapshot)
                        }
                    }
                    .onDisappear {
                        pinchController.cancelIfNeeded()
                    }
                    .onChange(of: isTabActive) { _, active in
                        if !active {
                            if let snapshot {
                                lastKnownContentHeight = snapshot.contentHeight
                            }
                            pinchController.cancelIfNeeded()
                        } else if let snapshot {
                            lastKnownContentHeight = snapshot.contentHeight
                            performPendingRevealIfNeeded(snapshot: snapshot, viewportHeight: effectiveViewportHeight)
                            prefetchAroundBucket(viewportBucket, snapshot: snapshot)
                        }
                    }
                    .onChange(of: store.scope) { _, _ in
                        guard assetsOverride == nil else { return }
                        pinchController.cancelIfNeeded()
                        if store.pendingRevealAssetID == nil {
                            resetViewportToTop(width: proxy.size.width, height: effectiveViewportHeight)
                        }
                    }
                    .onChange(of: proxy.size.width) { _, w in
                        lastKnownWidth = w
                    }
                    .onChange(of: store.pendingRevealAssetID) { _, _ in
                        if let snapshot {
                            performPendingRevealIfNeeded(snapshot: snapshot, viewportHeight: effectiveViewportHeight)
                        }
                    }
                    .onChange(of: displayedAssets.count) { oldCount, newCount in
                        if let snapshot {
                            lastKnownContentHeight = snapshot.contentHeight
                            if oldCount == 0 && newCount > 0 && store.pendingRevealAssetID == nil {
                                resetViewportToTop(width: proxy.size.width, height: effectiveViewportHeight)
                            }
                            performPendingRevealIfNeeded(snapshot: snapshot, viewportHeight: effectiveViewportHeight)
                        }
                    }
                }
            }

            if store.isMultiSelectMode {
                VStack {
                    Spacer()
                    multiSelectFloatingDock
                        .padding(.horizontal, MobileTheme.Space.lg)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $isFilterSheetPresented) {
            NavigationStack {
                FilterOptionsSheet(store: store)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isBatchFolderSheetPresented) {
            let selectedAssets = displayedAssets.filter { store.selectedAssetIDs.contains($0.id) }
            let distinctFolderIDs = Set(selectedAssets.map(\.folderID))
            let sharedCurrentFolderID: UUID? = distinctFolderIDs.count == 1 ? (distinctFolderIDs.first ?? nil) : nil
            NavigationStack {
                HierarchicalFolderPickerSheet(
                    title: "移动到文件夹",
                    folderTree: store.folderTree,
                    currentFolderID: sharedCurrentFolderID,
                    onPick: { folderID, folderName in
                        let ids = Array(store.selectedAssetIDs)
                        isBatchFolderSheetPresented = false
                        store.isMultiSelectMode = false
                        store.selectedAssetIDs.removeAll()
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(
                                    assetIDs: ids,
                                    folderAssignment: folderID.map { .folder($0) } ?? .inbox
                                ),
                                successToast: folderID == nil
                                    ? "已将 \(ids.count) 项移回收件箱"
                                    : "已将 \(ids.count) 项归档到「\(folderName)」"
                            )
                        }
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $singleMoveAsset) { target in
            NavigationStack {
                HierarchicalFolderPickerSheet(
                    title: "移动到文件夹",
                    folderTree: store.folderTree,
                    currentFolderID: target.folderID,
                    onPick: { folderID, folderName in
                        let id = target.id
                        singleMoveAsset = nil
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(
                                    assetIDs: [id],
                                    folderAssignment: folderID.map { .folder($0) } ?? .inbox
                                ),
                                successToast: folderID == nil ? "已移回收件箱" : "已归档到「\(folderName)」"
                            )
                        }
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isBatchBoardSheetPresented) {
            NavigationStack {
                BatchBoardPickerSheet(
                    store: store,
                    assetIDs: Array(store.selectedAssetIDs),
                    onDone: {
                        isBatchBoardSheetPresented = false
                        store.isMultiSelectMode = false
                        store.selectedAssetIDs.removeAll()
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(
            get: { shareAssetURL != nil },
            set: { if !$0 { shareAssetURL = nil } }
        )) {
            if let shareAssetURL {
                ActivityShareSheet(items: [shareAssetURL])
            }
        }
        .confirmationDialog(
            "永久删除选中的 \(store.selectedAssetIDs.count) 项素材？",
            isPresented: $confirmPermanentDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                let ids = Array(store.selectedAssetIDs)
                store.isMultiSelectMode = false
                store.selectedAssetIDs.removeAll()
                Task { await store.permanentlyDelete(ids: ids) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销，云端同步记录也会同步移除这些素材。")
        }
        .confirmationDialog(
            "永久删除此素材？",
            isPresented: Binding(
                get: { singleDeleteAssetID != nil },
                set: { if !$0 { singleDeleteAssetID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                if let id = singleDeleteAssetID {
                    singleDeleteAssetID = nil
                    Task { await store.permanentlyDelete(ids: [id]) }
                }
            }
            Button("取消", role: .cancel) { singleDeleteAssetID = nil }
        } message: {
            Text("彻底删除后将无法从回收站恢复。")
        }
    }

    // MARK: - Exact Reveal-in-Library Scroll Compensation

    private func resetViewportToTop(width: CGFloat, height: CGFloat) {
        scrollTracker.liveScrollY = 0
        viewportBucket = GalleryViewportBucket(minY: 0, width: width, height: height)
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            scrollPosition.scrollTo(edge: .top)
        }
    }

    private func performPendingRevealIfNeeded(snapshot: VirtualizedMasonrySnapshot, viewportHeight: CGFloat) {
        guard let revealID = store.pendingRevealAssetID,
              let rect = snapshot.rectByID[revealID] else {
            return
        }
        store.pendingRevealAssetID = nil
        let maxScrollY = max(0, snapshot.contentHeight - max(200, viewportHeight))
        let targetY = max(0, min(maxScrollY, rect.midY - viewportHeight * 0.42))
        DispatchQueue.main.async {
            scrollTracker.liveScrollY = targetY
            viewportBucket = GalleryViewportBucket(
                minY: targetY,
                width: lastKnownWidth,
                height: viewportHeight
            )
            withAnimation(MobileMotion.accessible(MobileMotion.drawerEase, reduced: reduceMotion)) {
                scrollPosition.scrollTo(y: targetY)
            }
        }
    }

    private func prefetchAroundBucket(_ bucket: GalleryViewportBucket, snapshot: VirtualizedMasonrySnapshot) {
        let base = bucket.cullingRect
        let lookaheadRect = CGRect(
            x: 0,
            y: max(0, base.minY - 400),
            width: base.width,
            height: base.height + 1_400
        )
        let upcomingIDs = snapshot.visibleItems(in: lookaheadRect, overscan: 0).map(\.id)
        if !upcomingIDs.isEmpty {
            store.thumbnails.prefetch(assetIDs: upcomingIDs, tier: .grid520)
        }
    }

    // MARK: - iOS Photos-Style Floating Header (Real iOS 26+ Liquid Glass Cluster)

    private var photosFloatingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                // Leading bold scope title + item count (tapping opens 目录与筛选)
                Button {
                    if let onOpenFolders {
                        MobileHaptics.light()
                        onOpenFolders()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(store.currentScopeTitle)
                                .font(.system(size: 27, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if onOpenFolders != nil {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .offset(y: 1)
                            }
                        }
                        Text(headerSubtitle)
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .shadow(color: MobileTheme.galleryGround(for: colorScheme).opacity(0.65), radius: 6, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                // Trailing floating controls using native iOS 26+ Liquid Glass cluster
                CharkleGlassCluster(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            MobileHaptics.light()
                            isFilterSheetPresented = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(
                                    store.hasActiveFilters ? MobileTheme.accent(for: colorScheme) : .primary
                                )
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCircle(interactive: true)
                        .accessibilityLabel("筛选与排序")

                        Button {
                            MobileHaptics.light()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                store.isMultiSelectMode.toggle()
                                if !store.isMultiSelectMode {
                                    store.selectedAssetIDs.removeAll()
                                }
                            }
                        } label: {
                            Text(store.isMultiSelectMode ? "取消" : "选取")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(
                                    store.isMultiSelectMode ? MobileTheme.accent(for: colorScheme) : .primary
                                )
                                .padding(.horizontal, 15)
                                .frame(height: 40)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCapsule(interactive: true)

                        Button(action: onOpenCapture) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 40, height: 40)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .charkleFloatingCircle(interactive: true)
                        .accessibilityLabel("新增素材")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            if store.hasActiveFilters {
                activeFilterChipsStrip
                    .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 8)
        .background(
            // Subtle progressive top readability scrim so full-bleed artwork still refracts cleanly through Liquid Glass
            LinearGradient(
                colors: [
                    MobileTheme.galleryGround(for: colorScheme).opacity(0.68),
                    MobileTheme.galleryGround(for: colorScheme).opacity(0.26),
                    MobileTheme.galleryGround(for: colorScheme).opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        )
    }

    private var headerSubtitle: String {
        if store.isMultiSelectMode {
            return store.selectedAssetIDs.isEmpty
                ? "横划可连续多选素材"
                : "已选取 \(store.selectedAssetIDs.count) 个项目"
        }
        if store.syncStatus.isSyncing {
            return store.syncStatus.localizedPhaseTitle
        }
        return "\(displayedAssets.count) 个项目"
    }

    private var activeFilterChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !store.criteria.searchQuery.isEmpty {
                    filterChip("“\(store.criteria.searchQuery)”") {
                        store.updateSearchQuery("")
                    }
                }
                if let hex = store.criteria.selectedColorHex {
                    filterChip(hex.uppercased(), dotHex: hex) {
                        store.setColorFilter(nil)
                    }
                }
                ForEach(Array(store.criteria.kinds).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                    filterChip(kind.localizedLabel) {
                        store.criteria.kinds.remove(kind)
                        Task { await store.reloadAssets() }
                    }
                }
                if let shape = store.criteria.shape {
                    filterChip(shape.localizedLabel) {
                        store.criteria.shape = nil
                        Task { await store.reloadAssets() }
                    }
                }
                if store.criteria.minRating > 0 {
                    filterChip("\(store.criteria.minRating)★+") {
                        store.criteria.minRating = 0
                        Task { await store.reloadAssets() }
                    }
                }
                ForEach(store.criteria.tags.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }), id: \.self) { tag in
                    filterChip("#\(tag)") {
                        store.criteria.tags.remove(tag)
                        Task { await store.reloadAssets() }
                    }
                }
                if store.criteria.onlyPinnedOffline {
                    filterChip("本地保留") {
                        store.criteria.onlyPinnedOffline = false
                        Task { await store.reloadAssets() }
                    }
                }
                Button("清除") {
                    store.clearFilters()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.accent(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .charkleFloatingCapsule(interactive: true)
            }
        }
    }

    private func filterChip(_ text: String, dotHex: String? = nil, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                if let dotHex {
                    Circle()
                        .fill(Color(charkleHex: dotHex))
                        .frame(width: 10, height: 10)
                }
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .charkleFloatingCapsule(interactive: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apple Photos-Style Drag-to-Multi-Select Sweep

    private func dragMultiSelectGesture(snapshot: VirtualizedMasonrySnapshot?) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named("galleryViewport"))
            .onChanged { value in
                guard store.isMultiSelectMode, !pinchController.isMorphActive, let snapshot else { return }
                let scrollY = max(0, pinchController.currentNormalizedScrollY ?? scrollTracker.liveScrollY)
                let startContent = CGPoint(x: value.startLocation.x, y: value.startLocation.y + scrollY)
                let currentContent = CGPoint(x: value.location.x, y: value.location.y + scrollY)

                if dragDecision == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    if dx >= dy * 0.78, let startID = snapshot.hitAssetID(at: startContent) {
                        dragDecision = .sweepSelect
                        dragStartAssetID = startID
                        preDragSelection = store.selectedAssetIDs
                        dragAddsSelection = !store.selectedAssetIDs.contains(startID)
                        lastSweptAssetID = startID
                        applyRangeSelection(from: startID, to: startID)
                        MobileHaptics.light()
                    } else {
                        dragDecision = .scroll
                    }
                }

                guard dragDecision == .sweepSelect,
                      let anchorID = dragStartAssetID,
                      let hitID = snapshot.hitAssetID(at: currentContent) else {
                    return
                }
                if hitID != lastSweptAssetID {
                    lastSweptAssetID = hitID
                    applyRangeSelection(from: anchorID, to: hitID)
                    MobileHaptics.light()
                }
            }
            .onEnded { _ in
                dragDecision = nil
                dragStartAssetID = nil
                lastSweptAssetID = nil
                preDragSelection = []
            }
    }

    private func applyRangeSelection(from startID: UUID, to endID: UUID) {
        guard let startIdx = displayedAssets.firstIndex(where: { $0.id == startID }),
              let endIdx = displayedAssets.firstIndex(where: { $0.id == endID }) else {
            return
        }
        let lower = min(startIdx, endIdx)
        let upper = max(startIdx, endIdx)
        let rangeIDs = Set(displayedAssets[lower...upper].map(\.id))
        if dragAddsSelection {
            store.selectedAssetIDs = preDragSelection.union(rangeIDs)
        } else {
            store.selectedAssetIDs = preDragSelection.subtracting(rangeIDs)
        }
    }

    private func toggleSelection(_ id: UUID) {
        MobileHaptics.light()
        if store.selectedAssetIDs.contains(id) {
            store.selectedAssetIDs.remove(id)
        } else {
            store.selectedAssetIDs.insert(id)
        }
    }

    private func shareAsset(_ asset: AssetRecord) async {
        if let url = try? await store.engine.originalURL(for: asset.id) {
            shareAssetURL = url
        } else if let thumb = await store.engine.thumbnailURL(for: asset.id, tier: .preview1400) {
            shareAssetURL = thumb
        } else {
            store.showToast("暂无法获取可分享的原图", tone: .warning)
        }
    }

    // MARK: - Sync Progress Banner

    private func syncProgressBanner(fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(store.syncStatus.localizedPhaseTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(Int((max(0, min(1, fraction)) * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            }
            ProgressView(value: max(0, min(1, fraction)))
                .tint(MobileTheme.accent(for: colorScheme))
            if let detail = store.syncStatus.currentDetail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    // MARK: - Multi-Select Floating Dock

    private var multiSelectFloatingDock: some View {
        let extractableCount = displayedAssets.filter {
            store.selectedAssetIDs.contains($0.id) && $0.hasExtractableLinkMedia
        }.count

        return HStack(spacing: MobileTheme.Space.sm) {
            Button {
                if store.selectedAssetIDs.count == displayedAssets.count {
                    store.selectedAssetIDs.removeAll()
                } else {
                    store.selectedAssetIDs = Set(displayedAssets.map(\.id))
                }
                MobileHaptics.light()
            } label: {
                Text(store.selectedAssetIDs.count == displayedAssets.count ? "全不选" : "全选")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
            }
            .buttonStyle(.plain)

            Text("已选 \(store.selectedAssetIDs.count)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .lineLimit(1)

            Spacer(minLength: 2)

            if extractableCount > 0 {
                Button {
                    let ids = store.selectedAssetIDs
                    MobileHaptics.light()
                    Task {
                        let count = await store.extractMediaFromSelectedLinks(ids)
                        if count > 0 {
                            store.isMultiSelectMode = false
                            store.selectedAssetIDs.removeAll()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if store.isExtractingSocialMedia {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "square.and.arrow.down.on.square")
                        }
                        Text("提取(\(extractableCount))")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
                .disabled(store.isExtractingSocialMedia)
            }

            Button {
                isBatchBoardSheetPresented = true
            } label: {
                Label("情绪板", systemImage: "rectangle.3.group")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .disabled(store.selectedAssetIDs.isEmpty)

            Button {
                isBatchFolderSheetPresented = true
            } label: {
                Label("移动", systemImage: "folder")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .disabled(store.selectedAssetIDs.isEmpty)

            Menu {
                Button {
                    let ids = Array(store.selectedAssetIDs)
                    let title = "Charkle参考(\(ids.count))"
                    Task {
                        if let url = await store.exportAssetsPureRefURL(assetIDs: ids, title: title) {
                            shareAssetURL = url
                        }
                    }
                } label: {
                    Label("导出 PureRef (.pur)", systemImage: "square.grid.2x2")
                }

                if store.scope == .trash {
                    Button {
                        let ids = Array(store.selectedAssetIDs)
                        store.isMultiSelectMode = false
                        store.selectedAssetIDs.removeAll()
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: ids, isTrashed: false),
                                successToast: "已恢复 \(ids.count) 项素材"
                            )
                        }
                    } label: {
                        Label("恢复素材", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        confirmPermanentDelete = true
                    } label: {
                        Label("永久删除", systemImage: "trash.slash")
                    }
                } else {
                    Button(role: .destructive) {
                        let ids = Array(store.selectedAssetIDs)
                        store.isMultiSelectMode = false
                        store.selectedAssetIDs.removeAll()
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: ids, isTrashed: true),
                                successToast: "已将 \(ids.count) 项移入回收站",
                                actionTitle: "撤销",
                                onAction: {
                                    Task {
                                        await store.patchAssets(
                                            AssetBatchPatch(assetIDs: ids, isTrashed: false),
                                            successToast: "已恢复 \(ids.count) 项素材"
                                        )
                                    }
                                }
                            )
                        }
                    } label: {
                        Label("移入回收站", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .medium))
            }
            .disabled(store.selectedAssetIDs.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .charkleFloatingCapsule(interactive: true)
    }

    // MARK: - Empty States (DESIGN.md §5.2 Miniature UI Vignettes)

    @ViewBuilder
    private var emptyStateView: some View {
        if store.hasActiveFilters {
            MobileEmptyStateView(
                kind: .noSearchResults,
                title: "没有匹配的素材",
                subtitle: "放宽关键词、颜色或格式筛选条件后再试试。",
                primaryActionTitle: "清除筛选",
                primaryAction: { store.clearFilters() }
            )
        } else {
            switch store.scope {
            case .trash:
                MobileEmptyStateView(
                    kind: .emptyTrash,
                    title: "回收站是空的",
                    subtitle: "软删除的素材会暂存在这里，支持随时恢复。"
                )
            case .folder:
                MobileEmptyStateView(
                    kind: .emptyFolder,
                    title: "这个文件夹还是空的",
                    subtitle: "从相册、链接或系统分享面板收藏素材到此处。",
                    primaryActionTitle: "立即采集",
                    primaryAction: onOpenCapture
                )
            default:
                MobileEmptyStateView(
                    kind: .emptyLibrary,
                    title: "开始建立你的随身视觉库",
                    subtitle: "连接 Google Drive 或 iCloud 同步已有桌面库，或直接采集图片与灵感链接。",
                    primaryActionTitle: store.hasConnectedCloudBackend ? "立即采集" : "配置云同步",
                    primaryAction: store.hasConnectedCloudBackend ? onOpenCapture : onOpenSyncSettings,
                    secondaryActionTitle: "载入示例库",
                    secondaryAction: {
                        Task { await store.seedSampleLibrary() }
                    }
                )
            }
        }
    }
}

// MARK: - Pure-Image Waterfall Card + 1:1 Desktop-Matched Long-Press Menu

struct GalleryCardView: View {
    let asset: AssetRecord
    @Bindable var store: MobileAppStore
    let zoomNamespace: Namespace.ID
    let zoomOrigin: PreviewZoomOrigin
    var cornerRadius: CGFloat = MobileTheme.Radius.cardOuter
    var isDenseOverview: Bool = false
    let isMultiSelect: Bool
    let isSelected: Bool
    var isHighlighted: Bool = false
    var isMorphing: Bool = false
    let onTap: () -> Void
    let onFindSimilar: () -> Void
    let onShareOriginal: () -> Void
    let onRequestPermanentDelete: () -> Void
    let onSelectMultiple: () -> Void
    var onOpenFolderPicker: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    private var resolvedDisplayImage: UIImage? {
        store.thumbnails.cachedImage(for: asset.id, tier: .grid520) ?? image
    }

    private var resolvedAspectRatio: CGFloat {
        MobileMasonryLayout.effectiveAspectRatio(for: asset, loadedImage: resolvedDisplayImage)
    }

    private var placeholderColor: Color {
        if let hex = asset.dominantColors.first?.hex {
            return Color(charkleHex: hex).opacity(colorScheme == .dark ? 0.32 : 0.20)
        }
        return MobileTheme.surfaceSubtle(for: colorScheme)
    }

    var body: some View {
        let displayImage = resolvedDisplayImage
        Button(action: onTap) {
            Color.clear
                .aspectRatio(resolvedAspectRatio, contentMode: .fit)
                .overlay {
                    if let displayImage {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholderColor
                            .overlay {
                                if !isDenseOverview && (asset.mediaKind == .audio || asset.mediaKind == .document) {
                                    VStack(spacing: 6) {
                                        Image(systemName: iconForKind(asset.mediaKind))
                                            .font(.system(size: 20, weight: .medium))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                        Text(asset.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 8)
                                    }
                                }
                            }
                    }
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    if !isDenseOverview && (mediaBadgeText != nil || asset.pinnedOffline) {
                        HStack(spacing: 4) {
                            if let badge = mediaBadgeText {
                                Text(badge)
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        .black.opacity(0.58),
                                        in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardInnerBadge, style: .continuous)
                                    )
                            }
                            Spacer(minLength: 0)
                            if asset.pinnedOffline {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4.5)
                                    .background(
                                        .black.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardInnerBadge, style: .continuous)
                                    )
                            }
                        }
                        .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isMultiSelect {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? MobileTheme.accent(for: colorScheme) : .white)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            (isSelected || isHighlighted)
                                ? MobileTheme.accent(for: colorScheme)
                                : MobileTheme.hairline(for: colorScheme),
                            lineWidth: isHighlighted ? 3.2 : (isSelected ? 2.5 : 0.5)
                        )
                )
                .shadow(
                    color: isHighlighted ? MobileTheme.accent(for: colorScheme).opacity(0.42) : .clear,
                    radius: isHighlighted ? 14 : 0
                )
                .scaleEffect(isHighlighted ? 1.025 : 1.0)
                .animation(MobileMotion.settleStrong, value: isHighlighted)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(MobileTactileButtonStyle())
        .matchedTransitionSource(
            id: PreviewZoomSourceID(origin: zoomOrigin, assetID: asset.id),
            in: zoomNamespace
        ) { configuration in
            configuration
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .contextMenu {
            if !isMorphing {
                desktopParityContextMenu
            }
        }
        .task(id: "\(asset.id.uuidString)-\(store.thumbnails.revision)") {
            if store.thumbnails.cachedImage(for: asset.id, tier: .grid520) != nil {
                return
            }
            let loaded = await store.thumbnails.loadImage(for: asset.id, tier: .grid520)
            if let loaded {
                image = loaded
            }
        }
    }

    // MARK: - 1:1 Desktop Right-Click Context Menu Parity

    @ViewBuilder
    private var desktopParityContextMenu: some View {
        Button {
            onTap()
        } label: {
            Label(
                asset.isExternalWebLink ? "在浏览器中打开" : "快速预览",
                systemImage: asset.isExternalWebLink ? "safari" : "eye"
            )
        }

        if asset.isTrashed {
            Divider()
            Button {
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: [asset.id], isTrashed: false),
                        successToast: "已放回原处"
                    )
                }
            } label: {
                Label("放回原处", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                onRequestPermanentDelete()
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
        } else {
            Divider()

            Button {
                Task { await store.copyAssetToPasteboard(asset) }
            } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }

            Button(action: onShareOriginal) {
                Label("分享原图", systemImage: "square.and.arrow.up")
            }

            Divider()

            Menu {
                ForEach(store.boards) { board in
                    Button(board.title) {
                        Task { await store.addAssets([asset.id], toBoard: board.id) }
                    }
                }
                if !store.boards.isEmpty {
                    Divider()
                }
                Button {
                    let id = asset.id
                    let title = asset.title
                    Task { _ = await store.createMoodboard(title: title, seedAssetIDs: [id]) }
                } label: {
                    Label("新建情绪板并加入", systemImage: "plus")
                }
            } label: {
                Label("加入情绪板…", systemImage: "rectangle.3.group")
            }

            Menu {
                ForEach((1...5).reversed(), id: \.self) { stars in
                    Button {
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: [asset.id], rating: stars),
                                successToast: "已评为 \(stars) 星"
                            )
                        }
                    } label: {
                        Label(
                            String(repeating: "★", count: stars) + (asset.rating == stars ? "  ✓" : ""),
                            systemImage: asset.rating == stars ? "star.fill" : "star"
                        )
                    }
                }
                if asset.rating > 0 {
                    Divider()
                    Button("清除评分") {
                        Task {
                            await store.patchAssets(AssetBatchPatch(assetIDs: [asset.id], rating: 0))
                        }
                    }
                }
            } label: {
                Label(
                    asset.rating > 0 ? "评分（\(asset.rating)★）" : "评分",
                    systemImage: asset.rating > 0 ? "star.fill" : "star"
                )
            }

            Button {
                Task { await store.retagAssets([asset.id]) }
            } label: {
                Label("AI 重新打标", systemImage: "sparkles")
            }

            Button(action: onFindSimilar) {
                Label("查找相似素材", systemImage: "sparkle.magnifyingglass")
            }

            Menu {
                Button {
                    Task {
                        await store.patchAssets(
                            AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .inbox),
                            successToast: "已移回收件箱"
                        )
                    }
                } label: {
                    Label(
                        asset.folderID == nil ? "收件箱  ✓" : "收件箱",
                        systemImage: "tray"
                    )
                }
                if !store.folderTree.isEmpty {
                    Divider()
                    HierarchicalFolderMenuContent(
                        nodes: store.folderTree,
                        currentFolderID: asset.folderID
                    ) { folderID, folderName in
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .folder(folderID)),
                                successToast: "已归档到「\(folderName)」"
                            )
                        }
                    }
                    if let onOpenFolderPicker {
                        Divider()
                        Button(action: onOpenFolderPicker) {
                            Label("按层级浏览并搜索…", systemImage: "list.bullet.indent")
                        }
                    }
                }
            } label: {
                Label("移动到文件夹", systemImage: "folder.badge.plus")
            }

            Button {
                let next = !asset.pinnedOffline
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: [asset.id], pinnedOffline: next),
                        successToast: next ? "已始终保留在本地" : "已取消始终保留在本地"
                    )
                }
            } label: {
                Label(
                    asset.pinnedOffline ? "取消始终保留在本地" : "始终保留在本地",
                    systemImage: asset.pinnedOffline ? "icloud" : "arrow.down.circle"
                )
            }

            if let hex = asset.dominantColors.first?.hex.uppercased() {
                Button {
                    UIPasteboard.general.string = hex
                    MobileHaptics.light()
                    store.showToast("已复制主色 \(hex)", tone: .info)
                } label: {
                    Label("复制主色 \(hex)", systemImage: "paintpalette")
                }

                Button {
                    store.setColorFilter(hex)
                } label: {
                    Label("按主色筛图", systemImage: "eyedropper")
                }
            }

            if let post = asset.richMetadata?.socialPost, (!post.effectiveAttachments.isEmpty || post.isZeroDownloadVideoBookmark) {
                Button {
                    let target = asset
                    Task { _ = await store.extractAllMediaFromSocialPost(postAsset: target) }
                } label: {
                    Label(
                        post.isZeroDownloadVideoBookmark
                            ? "保存视频为独立素材"
                            : "提取帖子内媒体为独立素材（\(post.effectiveAttachments.count) 项）",
                        systemImage: post.isZeroDownloadVideoBookmark ? "film.stack" : "square.and.arrow.down.on.square"
                    )
                }
            } else if let web = asset.richMetadata?.webPage, !web.attachments.isEmpty {
                Button {
                    let target = asset
                    Task { _ = await store.extractAllMediaFromLinkAsset(target) }
                } label: {
                    Label(
                        web.hasVideo ? "保存网页视频为独立素材" : "提取网页媒体为独立素材（\(web.attachments.count) 项）",
                        systemImage: web.hasVideo ? "film.stack" : "square.and.arrow.down.on.square"
                    )
                }
            }

            Button(action: onSelectMultiple) {
                Label("多选批处理", systemImage: "checkmark.circle")
            }

            Divider()

            Button(role: .destructive) {
                let targetID = asset.id
                Task {
                    await store.patchAssets(
                        AssetBatchPatch(assetIDs: [targetID], isTrashed: true),
                        successToast: "已移至回收站",
                        actionTitle: "撤销",
                        onAction: {
                            Task {
                                await store.patchAssets(
                                    AssetBatchPatch(assetIDs: [targetID], isTrashed: false),
                                    successToast: "已恢复素材"
                                )
                            }
                        }
                    )
                }
            } label: {
                Label("移至回收站", systemImage: "trash")
            }
        }
    }

    private var mediaBadgeText: String? {
        if let post = asset.richMetadata?.socialPost {
            return post.platform.displayName
        }
        if asset.isGitHubRepo {
            return "GitHub"
        }
        switch asset.mediaKind {
        case .animatedImage:
            return "GIF"
        case .video:
            if let dur = asset.durationSeconds, dur > 0 {
                let mins = Int(dur) / 60
                let secs = Int(dur) % 60
                return String(format: "%d:%02d", mins, secs)
            }
            return "视频"
        case .webBookmark:
            return asset.sourceDomain ?? "网页"
        case .audio:
            return "音频"
        case .model3D:
            return "3D"
        case .document:
            return (asset.fileName as NSString).pathExtension.uppercased()
        case .image, .designFile:
            return nil
        }
    }

    private func iconForKind(_ kind: MediaKind) -> String {
        switch kind {
        case .audio: "waveform"
        case .document: "doc.text"
        case .video: "play.rectangle"
        case .model3D: "cube"
        case .webBookmark: "globe"
        default: "photo"
        }
    }
}

// MARK: - Batch Moodboard Picker

private struct BatchBoardPickerSheet: View {
    @Bindable var store: MobileAppStore
    let assetIDs: [UUID]
    let onDone: () -> Void
    @State private var newBoardTitle = ""

    var body: some View {
        List {
            Section("加入已有情绪板") {
                if store.boards.isEmpty {
                    Text("尚无情绪板，可在下方直接新建")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.boards) { board in
                        Button {
                            Task {
                                await store.addAssets(assetIDs, toBoard: board.id)
                                onDone()
                            }
                        } label: {
                            HStack {
                                Label(board.title, systemImage: "rectangle.3.group")
                                Spacer()
                                Text("\(board.itemCount) 项")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("新建情绪板并加入（\(assetIDs.count) 项）") {
                TextField("输入新情绪板名称…", text: $newBoardTitle)
                Button("创建并加入") {
                    let title = newBoardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        _ = await store.createMoodboard(
                            title: title.isEmpty ? "新建情绪板" : title,
                            seedAssetIDs: assetIDs
                        )
                        onDone()
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .navigationTitle("加入情绪板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: onDone)
            }
        }
    }
}

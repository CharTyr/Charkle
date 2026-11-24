import CharkleCore
import CoreGraphics
import Foundation

/// Output of the deterministic Auto Editorial layout solver.
public nonisolated struct EditorialLayoutResult: Sendable, Equatable {
    public let frames: [UUID: BoardRect]
    public let orderedNodeIDs: [UUID]
    public let contentSize: CGSize
    public let columnWidth: Double
    public let columnCount: Int

    public init(
        frames: [UUID: BoardRect],
        orderedNodeIDs: [UUID],
        contentSize: CGSize,
        columnWidth: Double,
        columnCount: Int
    ) {
        self.frames = frames
        self.orderedNodeIDs = orderedNodeIDs
        self.contentSize = contentSize
        self.columnWidth = columnWidth
        self.columnCount = columnCount
    }
}

/// Deterministic O(N) auto-editorial Bento / Masonry layout solver supporting
/// `.balanced`, `.magazine` (Hero 2× span), and `.compact` editorial styles,
/// plus zero-jump freezing from `.autoEditorial` into `.freeform`.
public nonisolated enum EditorialLayoutSolver {
    public static func solve(
        nodes: [BoardNode],
        config: AutoLayoutConfig,
        containerWidth: Double,
        assetsByID: [UUID: AssetRecord],
        padding: Double = 28
    ) -> EditorialLayoutResult {
        let effectivePadding: Double = switch config.style {
        case .magazine: max(36, padding + 10)
        case .balanced: max(22, padding)
        case .compact: max(12, min(padding, 14))
        }
        let usableWidth = max(320, containerWidth - effectivePadding * 2)
        let styleSpacing: Double = switch config.style {
        case .magazine: max(26, config.spacing + 10)
        case .balanced: max(15, config.spacing)
        case .compact: 6
        }

        let cols: Int = switch config.style {
        case .magazine:
            max(2, min(3, Int((usableWidth + styleSpacing) / 280.0)))
        case .balanced:
            max(3, min(4, Int((usableWidth + styleSpacing) / 220.0)))
        case .compact:
            max(5, min(7, Int((usableWidth + styleSpacing) / 142.0)))
        }

        let colWidth = (usableWidth - styleSpacing * Double(cols - 1)) / Double(cols)
        let sortedNodes = nodes.sorted { lhs, rhs in
            if lhs.editorialOrder != rhs.editorialOrder {
                return lhs.editorialOrder < rhs.editorialOrder
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var columnHeights = Array(repeating: effectivePadding, count: cols)
        var frames: [UUID: BoardRect] = [:]
        frames.reserveCapacity(sortedNodes.count)

        var heroQuota = config.style == .magazine ? 3 : 0
        var magazineHeroAssigned = false

        for (index, node) in sortedNodes.enumerated() {
            switch node.kind {
            case .groupFrame:
                let maxY = columnHeights.max() ?? effectivePadding
                let headerHeight = max(54.0, min(86.0, node.frame.height > 0 ? node.frame.height : 60.0))
                let rect = BoardRect(x: effectivePadding, y: maxY, width: usableWidth, height: headerHeight)
                frames[node.id] = rect
                let nextY = maxY + headerHeight + styleSpacing
                for c in 0..<cols { columnHeights[c] = nextY }

            case .paletteStrip:
                let maxY = columnHeights.max() ?? effectivePadding
                let stripHeight = config.style == .compact ? 56.0 : 76.0
                let rect = BoardRect(x: effectivePadding, y: maxY, width: usableWidth, height: stripHeight)
                frames[node.id] = rect
                let nextY = maxY + stripHeight + styleSpacing
                for c in 0..<cols { columnHeights[c] = nextY }

            case .note(_, let text, _, let fontSize):
                let col = shortestColumnIndex(in: columnHeights)
                let x = effectivePadding + Double(col) * (colWidth + styleSpacing)
                let y = columnHeights[col]
                let estimatedLines = max(3, min(10, Int(Double(text.count) / 18.0) + 2))
                let height = max(124.0, Double(estimatedLines) * max(18.0, fontSize * 1.45) + 42.0)
                let rect = BoardRect(x: x, y: y, width: colWidth, height: height)
                frames[node.id] = rect
                columnHeights[col] = y + height + styleSpacing

            case .assetRef(let assetID, let crop, let weight, _):
                let aspect = resolvedAspectRatio(for: assetID, crop: crop, assetsByID: assetsByID, style: config.style)
                let wantsHero: Bool
                if config.style == .magazine && cols >= 3 && heroQuota > 0 {
                    if !magazineHeroAssigned && index == 0 {
                        wantsHero = true
                    } else if weight >= 2 {
                        wantsHero = true
                    } else if index > 0 && index % 5 == 0 {
                        wantsHero = true
                    } else {
                        wantsHero = false
                    }
                } else {
                    wantsHero = false
                }

                if wantsHero, let spanStart = bestTwoColumnSpanStart(in: columnHeights) {
                    heroQuota -= 1
                    magazineHeroAssigned = true
                    let spanWidth = colWidth * 2 + styleSpacing
                    let clampedAspect = max(0.85, min(1.85, aspect))
                    let height = spanWidth / clampedAspect
                    let y = max(columnHeights[spanStart], columnHeights[spanStart + 1])
                    let x = effectivePadding + Double(spanStart) * (colWidth + styleSpacing)
                    let rect = BoardRect(x: x, y: y, width: spanWidth, height: height)
                    frames[node.id] = rect
                    let nextY = y + height + styleSpacing
                    columnHeights[spanStart] = nextY
                    columnHeights[spanStart + 1] = nextY
                } else {
                    let col = shortestColumnIndex(in: columnHeights)
                    let x = effectivePadding + Double(col) * (colWidth + styleSpacing)
                    let y = columnHeights[col]
                    let height = colWidth / aspect
                    let rect = BoardRect(x: x, y: y, width: colWidth, height: height)
                    frames[node.id] = rect
                    columnHeights[col] = y + height + styleSpacing
                }
            }
        }

        let maxHeight = (columnHeights.max() ?? effectivePadding) + effectivePadding + 88.0
        return EditorialLayoutResult(
            frames: frames,
            orderedNodeIDs: sortedNodes.map(\.id),
            contentSize: CGSize(width: containerWidth, height: max(480, maxHeight)),
            columnWidth: colWidth,
            columnCount: cols
        )
    }

    /// Smart Auto-Layout Frame reflow: packs all enclosed nodes cleanly inside `groupRect`
    /// using justified rows and proportionally scales them so every child stays strictly within
    /// the resized frame bounds in real time.
    public static func reflowNodesInsideGroupFrame(
        groupRect: BoardRect,
        childNodes: [BoardNode],
        assetsByID: [UUID: AssetRecord],
        headerHeight: Double = 38,
        padding: Double = 12,
        spacing: Double = 10
    ) -> [UUID: BoardRect] {
        guard !childNodes.isEmpty else { return [:] }
        let innerX = groupRect.x + padding
        let innerY = groupRect.y + headerHeight + padding * 0.6
        let innerW = max(80, groupRect.width - padding * 2)
        let innerH = max(60, groupRect.height - headerHeight - padding * 1.6)

        // Bucketed row/column ordering guarantees a strict weak ordering (transitive, cycle-free).
        let ordered = childNodes.sorted { lhs, rhs in
            let lRow = lhs.frame.minY.isFinite ? Int((lhs.frame.minY / 24.0).rounded()) : 0
            let rRow = rhs.frame.minY.isFinite ? Int((rhs.frame.minY / 24.0).rounded()) : 0
            if lRow != rRow { return lRow < rRow }
            let lCol = lhs.frame.minX.isFinite ? Int((lhs.frame.minX / 12.0).rounded()) : 0
            let rCol = rhs.frame.minX.isFinite ? Int((rhs.frame.minX / 12.0).rounded()) : 0
            if lCol != rCol { return lCol < rCol }
            if lhs.editorialOrder != rhs.editorialOrder { return lhs.editorialOrder < rhs.editorialOrder }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let ratios: [Double] = ordered.map { node in
            switch node.kind {
            case .assetRef(let assetID, let crop, _, _):
                return resolvedAspectRatio(for: assetID, crop: crop, assetsByID: assetsByID, style: .balanced)
            default:
                let raw = (node.frame.width.isFinite && node.frame.height.isFinite && node.frame.height > 0)
                    ? (node.frame.width / max(1, node.frame.height))
                    : 1.25
                return max(0.65, min(2.2, raw))
            }
        }

        // Choose the row count (1 ... min(n, 8)) that maximizes area fill inside (innerW x innerH) without overflowing
        let n = ordered.count
        var bestFrames: [UUID: BoardRect] = [:]
        var bestScore: Double = -Double.greatestFiniteMagnitude

        for rowCount in 1...min(n, 8) {
            let totalGapsY = spacing * Double(rowCount - 1)
            let availH = max(32, innerH - totalGapsY)
            // Partition items greedily by balanced aspect-ratio sum per row
            let totalRatio = ratios.reduce(0, +)
            let targetRowRatio = totalRatio / Double(rowCount)

            var rows: [[Int]] = []
            var currentRow: [Int] = []
            var currentSum: Double = 0
            for idx in 0..<n {
                currentRow.append(idx)
                currentSum += ratios[idx]
                let remainingRows = rowCount - rows.count - 1
                let remainingItems = n - idx - 1
                if remainingRows > 0 && (remainingItems == remainingRows || currentSum >= targetRowRatio * 0.88) {
                    rows.append(currentRow)
                    currentRow = []
                    currentSum = 0
                }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }

            // Natural height of each row if spanning full innerW
            var naturalRowHeights: [Double] = []
            for r in rows {
                let gapsX = spacing * Double(max(0, r.count - 1))
                let sumR = r.reduce(0.0) { $0 + ratios[$1] }
                let rowH = max(24, (innerW - gapsX) / max(0.1, sumR))
                naturalRowHeights.append(rowH)
            }

            let sumNaturalH = naturalRowHeights.reduce(0, +)
            let verticalScale = sumNaturalH > availH ? (availH / sumNaturalH) : 1.0

            var candidate: [UUID: BoardRect] = [:]
            var totalPaintedArea: Double = 0
            var overflowPenalty: Double = 0
            var cursorY = innerY

            for (rIdx, r) in rows.enumerated() {
                let rowH = max(20, naturalRowHeights[rIdx] * verticalScale)
                let gapsX = spacing * Double(max(0, r.count - 1))
                let rawRowW = r.reduce(0.0) { $0 + ratios[$1] * rowH } + gapsX
                let horizScale = rawRowW > innerW ? ((innerW - gapsX) / max(1, rawRowW - gapsX)) : 1.0
                let effectiveH = max(20, rowH * horizScale)

                var cursorX = innerX
                for itemIdx in r {
                    let w = max(20, ratios[itemIdx] * effectiveH)
                    let rect = BoardRect(x: cursorX, y: cursorY, width: w, height: effectiveH)
                    candidate[ordered[itemIdx].id] = rect
                    totalPaintedArea += w * effectiveH
                    if rect.maxX > innerX + innerW + 1 {
                        overflowPenalty += (rect.maxX - (innerX + innerW)) * effectiveH * 4
                    }
                    if rect.maxY > innerY + innerH + 1 {
                        overflowPenalty += (rect.maxY - (innerY + innerH)) * w * 4
                    }
                    cursorX += w + spacing
                }
                cursorY += effectiveH + spacing
            }

            let score = totalPaintedArea - overflowPenalty
            if score > bestScore {
                bestScore = score
                bestFrames = candidate
            }
        }

        return bestFrames
    }

    /// Freezes the exact computed Auto Editorial visual frames directly into every node's `frame`
    /// and switches the document to `.freeform` so nothing visually jumps!
    public static func freezeIntoFreeform(
        document: MoodboardDocument,
        containerWidth: Double,
        assetsByID: [UUID: AssetRecord]
    ) -> MoodboardDocument {
        var copy = document
        let config: AutoLayoutConfig = switch document.mode {
        case .autoEditorial(let cfg): cfg
        case .freeform: AutoLayoutConfig()
        }
        let solved = solve(
            nodes: document.nodes,
            config: config,
            containerWidth: containerWidth,
            assetsByID: assetsByID
        )
        for idx in copy.nodes.indices {
            let id = copy.nodes[idx].id
            if let rect = solved.frames[id] {
                copy.nodes[idx].frame = rect
            }
        }
        copy.mode = .freeform
        copy.viewportZoom = 1.0
        copy.viewportCenter = BoardPoint(
            x: solved.contentSize.width * 0.5,
            y: min(solved.contentSize.height * 0.5, 420)
        )
        return copy
    }

    /// Re-tidies either the selected unlocked nodes (around their bounding box origin) or all unlocked nodes
    /// into crisp editorial alignment while remaining in Freeform mode (zero cumulative drift).
    public static func tidyNodesInFreeform(
        document: MoodboardDocument,
        selectedNodeIDs: Set<UUID>,
        assetsByID: [UUID: AssetRecord]
    ) -> MoodboardDocument {
        var copy = document
        let unlockedSelection = copy.nodes.filter { selectedNodeIDs.contains($0.id) && !$0.isLocked }
        let targetNodes: [BoardNode] = selectedNodeIDs.count >= 2
            ? unlockedSelection
            : copy.nodes.filter { !$0.isLocked }
        guard !targetNodes.isEmpty else { return copy }

        let minX = targetNodes.map(\.frame.minX).filter(\.isFinite).min() ?? 40
        let minY = targetNodes.map(\.frame.minY).filter(\.isFinite).min() ?? 40
        let maxX = targetNodes.map(\.frame.maxX).filter(\.isFinite).max() ?? 1080
        let width = max(760, min(1440, maxX - minX + 56))

        let solved = solve(
            nodes: targetNodes,
            config: AutoLayoutConfig(columns: 4, spacing: 16, style: .balanced),
            containerWidth: width,
            assetsByID: assetsByID,
            padding: 0
        )

        let solvedOriginX = solved.frames.values.map(\.minX).min() ?? 0
        let solvedOriginY = solved.frames.values.map(\.minY).min() ?? 0

        for idx in copy.nodes.indices where !copy.nodes[idx].isLocked {
            let id = copy.nodes[idx].id
            if let rect = solved.frames[id] {
                copy.nodes[idx].frame = BoardRect(
                    x: minX + (rect.x - solvedOriginX),
                    y: minY + (rect.y - solvedOriginY),
                    width: rect.width,
                    height: rect.height
                )
            }
        }
        return copy
    }

    private static func resolvedAspectRatio(
        for assetID: UUID,
        crop: NormalizedCropRect?,
        assetsByID: [UUID: AssetRecord],
        style: EditorialStyle
    ) -> Double {
        let rawRatio = assetsByID[assetID]?.aspectRatio ?? 1.25
        var ratio = (rawRatio.isFinite && rawRatio > 0) ? rawRatio : 1.25
        if let crop, crop.width.isFinite, crop.height.isFinite, crop.width > 0.05, crop.height > 0.05 {
            ratio = ratio * (crop.width / crop.height)
        }
        guard ratio.isFinite && ratio > 0 else { return 1.25 }
        switch style {
        case .compact:
            return max(0.80, min(1.32, ratio))
        case .magazine:
            return max(0.56, min(2.15, ratio))
        case .balanced:
            return max(0.64, min(1.85, ratio))
        }
    }

    private static func shortestColumnIndex(in heights: [Double]) -> Int {
        var bestIdx = 0
        var bestVal = heights[0]
        for i in 1..<heights.count {
            if heights[i] < bestVal - 1.0 {
                bestVal = heights[i]
                bestIdx = i
            }
        }
        return bestIdx
    }

    private static func bestTwoColumnSpanStart(in heights: [Double]) -> Int? {
        guard heights.count >= 2 else { return nil }
        var bestStart = 0
        var bestMax = max(heights[0], heights[1])
        for i in 1..<(heights.count - 1) {
            let pairMax = max(heights[i], heights[i + 1])
            if pairMax < bestMax - 1.0 {
                bestMax = pairMax
                bestStart = i
            }
        }
        return bestStart
    }
}

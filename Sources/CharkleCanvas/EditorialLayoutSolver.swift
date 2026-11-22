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
        let usableWidth = max(320, containerWidth - padding * 2)
        let styleSpacing: Double = switch config.style {
        case .balanced: max(12, config.spacing)
        case .magazine: max(16, config.spacing + 4)
        case .compact: max(8, min(config.spacing, 10))
        }

        let adaptiveMaxCols = max(2, Int((usableWidth + styleSpacing) / 210.0))
        let requestedCols = max(2, min(6, config.columns))
        let cols: Int = switch config.style {
        case .compact: min(max(requestedCols + 1, 3), max(adaptiveMaxCols, 3))
        case .magazine: min(max(requestedCols, 3), max(adaptiveMaxCols, 3))
        case .balanced: min(requestedCols, max(adaptiveMaxCols, 2))
        }

        let colWidth = (usableWidth - styleSpacing * Double(cols - 1)) / Double(cols)
        let sortedNodes = nodes.sorted { lhs, rhs in
            if lhs.editorialOrder != rhs.editorialOrder {
                return lhs.editorialOrder < rhs.editorialOrder
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var columnHeights = Array(repeating: padding, count: cols)
        var frames: [UUID: BoardRect] = [:]
        frames.reserveCapacity(sortedNodes.count)

        var heroQuota = config.style == .magazine ? 2 : 1
        var magazineHeroAssigned = false

        for (index, node) in sortedNodes.enumerated() {
            switch node.kind {
            case .groupFrame:
                // In auto-editorial mode, section frames span the full row as crisp editorial headers.
                let maxY = columnHeights.max() ?? padding
                let headerHeight = max(56.0, min(92.0, node.frame.height > 0 ? node.frame.height : 64.0))
                let rect = BoardRect(x: padding, y: maxY, width: usableWidth, height: headerHeight)
                frames[node.id] = rect
                let nextY = maxY + headerHeight + styleSpacing
                for c in 0..<cols { columnHeights[c] = nextY }

            case .paletteStrip:
                let maxY = columnHeights.max() ?? padding
                let stripHeight = 76.0
                let rect = BoardRect(x: padding, y: maxY, width: usableWidth, height: stripHeight)
                frames[node.id] = rect
                let nextY = maxY + stripHeight + styleSpacing
                for c in 0..<cols { columnHeights[c] = nextY }

            case .note(_, let text, _, let fontSize):
                let col = shortestColumnIndex(in: columnHeights)
                let x = padding + Double(col) * (colWidth + styleSpacing)
                let y = columnHeights[col]
                let estimatedLines = max(3, min(10, Int(Double(text.count) / 18.0) + 2))
                let height = max(140.0, Double(estimatedLines) * max(18.0, fontSize * 1.45) + 46.0)
                let rect = BoardRect(x: x, y: y, width: colWidth, height: height)
                frames[node.id] = rect
                columnHeights[col] = y + height + styleSpacing

            case .assetRef(let assetID, let crop, let weight, _):
                let aspect = resolvedAspectRatio(for: assetID, crop: crop, assetsByID: assetsByID, style: config.style)
                let wantsHero: Bool
                if cols >= 3 {
                    if weight >= 2 && heroQuota > 0 {
                        wantsHero = true
                    } else if config.style == .magazine && !magazineHeroAssigned && index == 0 {
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
                    let clampedAspect = max(0.75, min(2.0, aspect))
                    let height = spanWidth / clampedAspect
                    let y = max(columnHeights[spanStart], columnHeights[spanStart + 1])
                    let x = padding + Double(spanStart) * (colWidth + styleSpacing)
                    let rect = BoardRect(x: x, y: y, width: spanWidth, height: height)
                    frames[node.id] = rect
                    let nextY = y + height + styleSpacing
                    columnHeights[spanStart] = nextY
                    columnHeights[spanStart + 1] = nextY
                } else {
                    let col = shortestColumnIndex(in: columnHeights)
                    let x = padding + Double(col) * (colWidth + styleSpacing)
                    let y = columnHeights[col]
                    let height = colWidth / aspect
                    let rect = BoardRect(x: x, y: y, width: colWidth, height: height)
                    frames[node.id] = rect
                    columnHeights[col] = y + height + styleSpacing
                }
            }
        }

        let maxHeight = (columnHeights.max() ?? padding) + padding + 88.0 // clearance for floating tool dock
        return EditorialLayoutResult(
            frames: frames,
            orderedNodeIDs: sortedNodes.map(\.id),
            contentSize: CGSize(width: containerWidth, height: max(480, maxHeight)),
            columnWidth: colWidth,
            columnCount: cols
        )
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

    /// Re-tidies either the selected nodes (around their bounding box origin) or the entire board
    /// into crisp editorial alignment while remaining in Freeform mode.
    public static func tidyNodesInFreeform(
        document: MoodboardDocument,
        selectedNodeIDs: Set<UUID>,
        assetsByID: [UUID: AssetRecord]
    ) -> MoodboardDocument {
        var copy = document
        let targetNodes: [BoardNode] = selectedNodeIDs.count >= 2
            ? copy.nodes.filter { selectedNodeIDs.contains($0.id) }
            : copy.nodes
        guard !targetNodes.isEmpty else { return copy }

        let minX = targetNodes.map(\.frame.minX).min() ?? 40
        let minY = targetNodes.map(\.frame.minY).min() ?? 40
        let maxX = targetNodes.map(\.frame.maxX).max() ?? 1080
        let width = max(760, min(1440, maxX - minX + 56))

        let solved = solve(
            nodes: targetNodes,
            config: AutoLayoutConfig(columns: 4, spacing: 16, style: .balanced),
            containerWidth: width,
            assetsByID: assetsByID,
            padding: 0
        )

        for idx in copy.nodes.indices {
            let id = copy.nodes[idx].id
            if let rect = solved.frames[id] {
                copy.nodes[idx].frame = BoardRect(
                    x: minX + rect.x,
                    y: minY + rect.y,
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
        var ratio = assetsByID[assetID]?.aspectRatio ?? 1.25
        if let crop, crop.width > 0.05, crop.height > 0.05 {
            ratio = ratio * (crop.width / crop.height)
        }
        switch style {
        case .compact:
            return max(0.72, min(1.75, ratio))
        case .magazine:
            return max(0.58, min(2.05, ratio))
        case .balanced:
            return max(0.62, min(1.95, ratio))
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

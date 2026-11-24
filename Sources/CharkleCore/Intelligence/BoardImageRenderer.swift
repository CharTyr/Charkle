import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure CoreGraphics / CoreText / ImageIO headless Moodboard PNG renderer.
///
/// Runs completely outside AppKit / MainActor so both the headless `charkle` MCP/CLI helper
/// and unit tests can render publication-grade moodboard snapshots without WindowServer startup.
public nonisolated enum BoardImageRenderer {
    public struct RenderOptions: Sendable {
        public var canvasWidth: CGFloat
        public var padding: CGFloat
        public var darkAppearance: Bool

        public init(
            canvasWidth: CGFloat = 1440,
            padding: CGFloat = 44,
            darkAppearance: Bool = false
        ) {
            self.canvasWidth = canvasWidth
            self.padding = padding
            self.darkAppearance = darkAppearance
        }
    }

    public static func renderPNG(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        thumbnailURL: (UUID) -> URL?,
        options: RenderOptions = RenderOptions()
    ) -> Data? {
        let pad = options.padding.isFinite ? max(16, min(120, options.padding)) : 44
        let rawWidth = options.canvasWidth.isFinite ? options.canvasWidth : 1440
        let width = max(840, min(2800, rawWidth))
        let contentWidth = width - pad * 2
        let headerHeight: CGFloat = document.subtitle.isEmpty ? 72 : 96
        let paletteHeight: CGFloat = document.extractedPalette.isEmpty ? 0 : 62

        // Compute normalized node rectangles in top-down coordinates (y = 0 at top of content area)
        let rawLaidOut = resolveTopDownLayout(
            document: document,
            assetsByID: assetsByID,
            contentWidth: contentWidth
        )

        let rawBodyHeight = max(240, rawLaidOut.nodes.map { $0.rect.maxY }.max() ?? 240)
        let maxBodyBudget = max(240, CGFloat(4600) - pad * 2 - headerHeight - paletteHeight)
        let verticalScale: CGFloat = rawBodyHeight > maxBodyBudget ? (maxBodyBudget / rawBodyHeight) : 1.0
        let laidOutNodes: [LaidOutNode] = verticalScale < 1.0
            ? rawLaidOut.nodes.map { item in
                LaidOutNode(
                    node: item.node,
                    rect: CGRect(
                        x: item.rect.origin.x * verticalScale,
                        y: item.rect.origin.y * verticalScale,
                        width: max(20, item.rect.size.width * verticalScale),
                        height: max(16, item.rect.size.height * verticalScale)
                    )
                )
            }
            : rawLaidOut.nodes
        let bodyHeight = max(240, rawBodyHeight * verticalScale)
        let totalHeight = min(4600, max(360, ceil(pad + headerHeight + paletteHeight + bodyHeight + pad)))

        guard width.isFinite, totalHeight.isFinite else { return nil }
        let pixelW = max(1, Int(width.rounded()))
        let pixelH = max(1, Int(totalHeight.rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high

        // Background
        let bg = options.darkAppearance
            ? CGColor(red: 0.086, green: 0.092, blue: 0.106, alpha: 1.0)
            : CGColor(red: 0.976, green: 0.974, blue: 0.966, alpha: 1.0)
        let fgPrimary = options.darkAppearance
            ? CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
            : CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        let fgSecondary = options.darkAppearance
            ? CGColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1.0)
            : CGColor(red: 0.42, green: 0.44, blue: 0.48, alpha: 1.0)
        let hairline = options.darkAppearance
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.12)
            : CGColor(red: 0, green: 0, blue: 0, alpha: 0.09)

        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))

        // Helper converting top-down rect into CoreGraphics bottom-left rect
        func cgRect(_ topDown: CGRect) -> CGRect {
            CGRect(
                x: topDown.origin.x,
                y: totalHeight - topDown.origin.y - topDown.size.height,
                width: topDown.size.width,
                height: topDown.size.height
            )
        }

        // 1. Header
        let titleText = document.title.isEmpty ? "Charkle Moodboard" : document.title
        drawText(
            titleText,
            in: cgRect(CGRect(x: pad, y: pad, width: contentWidth - 160, height: 38)),
            fontSize: 28,
            weight: .bold,
            color: fgPrimary,
            ctx: ctx
        )
        drawText(
            "CHARKLE · \(document.referencedAssetIDs.count) REFS",
            in: cgRect(CGRect(x: width - pad - 150, y: pad + 10, width: 150, height: 22)),
            fontSize: 11,
            weight: .semibold,
            color: fgSecondary,
            alignment: .right,
            ctx: ctx
        )
        if !document.subtitle.isEmpty {
            drawText(
                document.subtitle,
                in: cgRect(CGRect(x: pad, y: pad + 40, width: contentWidth, height: 34)),
                fontSize: 14,
                weight: .regular,
                color: fgSecondary,
                ctx: ctx
            )
        }

        // 2. Harmonized Palette Strip
        var cursorY = pad + headerHeight
        if !document.extractedPalette.isEmpty {
            let swatches = Array(document.extractedPalette.prefix(7))
            let swGap: CGFloat = 10
            let swWidth = floor((contentWidth - swGap * CGFloat(max(0, swatches.count - 1))) / CGFloat(max(1, swatches.count)))
            for (idx, swatch) in swatches.enumerated() {
                let x = pad + CGFloat(idx) * (swWidth + swGap)
                let chipRect = cgRect(CGRect(x: x, y: cursorY, width: swWidth, height: 34))
                let chipPath = CGPath(roundedRect: chipRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
                let rgb = hexToRGB(swatch.hex) ?? (0.5, 0.5, 0.5)
                ctx.saveGState()
                ctx.addPath(chipPath)
                ctx.setFillColor(CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0))
                ctx.fillPath()
                ctx.addPath(chipPath)
                ctx.setStrokeColor(hairline)
                ctx.setLineWidth(1)
                ctx.strokePath()
                ctx.restoreGState()

                drawText(
                    swatch.hex.uppercased(),
                    in: cgRect(CGRect(x: x, y: cursorY + 38, width: swWidth, height: 16)),
                    fontSize: 10.5,
                    weight: .medium,
                    color: fgSecondary,
                    ctx: ctx
                )
            }
            cursorY += paletteHeight
        }

        // 3. Nodes (groupFrames behind, then assetRefs & notes)
        let sorted = laidOutNodes.sorted { lhs, rhs in
            let lPriority = nodeLayerPriority(lhs.node.kind)
            let rPriority = nodeLayerPriority(rhs.node.kind)
            if lPriority != rPriority { return lPriority < rPriority }
            return lhs.node.zIndex < rhs.node.zIndex
        }

        var drawnRectsByNodeID: [UUID: (rect: CGRect, node: BoardNode)] = [:]
        for item in sorted {
            let shifted = CGRect(
                x: pad + item.rect.origin.x,
                y: cursorY + item.rect.origin.y,
                width: item.rect.size.width,
                height: item.rect.size.height
            )
            let rect = cgRect(shifted)
            drawnRectsByNodeID[item.node.id] = (rect, item.node)

            let rotDeg = item.node.rotationDegrees.isFinite ? item.node.rotationDegrees : 0
            ctx.saveGState()
            if abs(rotDeg) > 0.1 {
                // CoreGraphics bottom-left coordinates rotate counter-clockwise for positive radians,
                // so negate SwiftUI clockwise degrees.
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: CGFloat(-rotDeg * .pi / 180.0))
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
            }

            switch item.node.kind {
            case .groupFrame(let title, let tint):
                let fill = groupFillColor(tint: tint, dark: options.darkAppearance)
                let path = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setFillColor(fill)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(hairline)
                ctx.setLineWidth(1)
                ctx.strokePath()
                ctx.restoreGState()

                drawText(
                    title,
                    in: cgRect(CGRect(x: shifted.minX + 16, y: shifted.minY + 12, width: max(40, shifted.width - 32), height: 24)),
                    fontSize: 13.5,
                    weight: .semibold,
                    color: fgPrimary,
                    ctx: ctx
                )

            case .note(let noteTitle, let text, let style, _):
                let noteFill = noteFillColor(style: style, dark: options.darkAppearance)
                let noteTextColor = style == .ink
                    ? CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0)
                    : fgPrimary
                let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setFillColor(noteFill)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(hairline)
                ctx.setLineWidth(1)
                ctx.strokePath()
                ctx.restoreGState()

                var textTop = shifted.minY + 14
                if let noteTitle, !noteTitle.isEmpty {
                    drawText(
                        noteTitle,
                        in: cgRect(CGRect(x: shifted.minX + 16, y: textTop, width: max(40, shifted.width - 32), height: 22)),
                        fontSize: 13,
                        weight: .bold,
                        color: noteTextColor,
                        ctx: ctx
                    )
                    textTop += 24
                }
                drawWrappedText(
                    text,
                    in: cgRect(CGRect(
                        x: shifted.minX + 16,
                        y: textTop,
                        width: max(40, shifted.width - 32),
                        height: max(20, shifted.maxY - textTop - 12)
                    )),
                    fontSize: 12.5,
                    color: noteTextColor,
                    ctx: ctx
                )

            case .assetRef(let assetID, let crop, _, _):
                let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()

                let cardFill = options.darkAppearance
                    ? CGColor(red: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)
                    : CGColor(red: 0.92, green: 0.91, blue: 0.89, alpha: 1.0)
                ctx.setFillColor(cardFill)
                ctx.fill(rect)

                if let url = thumbnailURL(assetID), let baseImage = loadCGImage(at: url) {
                    let image: CGImage = {
                        guard let crop, crop != .full, crop.width > 0.04, crop.height > 0.04 else {
                            return baseImage
                        }
                        let clamped = crop.clamped()
                        let pixelRect = CGRect(
                            x: (clamped.x * Double(baseImage.width)).rounded(.down),
                            y: (clamped.y * Double(baseImage.height)).rounded(.down),
                            width: max(4, (clamped.width * Double(baseImage.width)).rounded()),
                            height: max(4, (clamped.height * Double(baseImage.height)).rounded())
                        ).intersection(CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
                        if pixelRect.width >= 4, pixelRect.height >= 4, let cropped = baseImage.cropping(to: pixelRect) {
                            return cropped
                        }
                        return baseImage
                    }()
                    let drawRect = aspectFillRect(
                        imageWidth: CGFloat(image.width),
                        imageHeight: CGFloat(image.height),
                        filling: rect
                    )
                    ctx.saveGState()
                    if item.node.flipHorizontal || item.node.flipVertical {
                        ctx.translateBy(x: rect.midX, y: rect.midY)
                        ctx.scaleBy(
                            x: item.node.flipHorizontal ? -1 : 1,
                            y: item.node.flipVertical ? -1 : 1
                        )
                        ctx.translateBy(x: -rect.midX, y: -rect.midY)
                    }
                    ctx.draw(image, in: drawRect)
                    ctx.restoreGState()
                } else if let color = assetsByID[assetID]?.dominantColors.first,
                          let rgb = hexToRGB(color.hex) {
                    ctx.setFillColor(CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0))
                    ctx.fill(rect)
                }
                ctx.restoreGState()

                ctx.saveGState()
                ctx.addPath(path)
                ctx.setStrokeColor(hairline)
                ctx.setLineWidth(1)
                ctx.strokePath()
                ctx.restoreGState()

            case .paletteStrip:
                // Palette strip is already rendered cleanly in the header band
                break
            }

            ctx.restoreGState()
        }

        // 4. Connectors & Freehand Ink Strokes
        for connector in document.connectors {
            guard let fromEntry = drawnRectsByNodeID[connector.fromNodeID],
                  let toEntry = drawnRectsByNodeID[connector.toNodeID] else { continue }
            drawConnector(ctx: ctx, connector: connector, from: fromEntry.rect, fromNode: fromEntry.node, to: toEntry.rect, toNode: toEntry.node)
        }
        if case .freeform = document.mode, let worldTransform = rawLaidOut.freeformTransform {
            let totalScale = worldTransform.scale * verticalScale
            for stroke in document.inkStrokes where stroke.points.count >= 2 {
                let rgb = hexToRGB(stroke.colorHex) ?? (0.85, 0.36, 0.28)
                let alpha = stroke.opacity.isFinite ? max(0.05, min(1.0, stroke.opacity)) : 0.92
                let lw = stroke.lineWidth.isFinite ? max(1.0, CGFloat(stroke.lineWidth) * totalScale) : 2.5
                let cgPts: [CGPoint] = stroke.points.compactMap { pt in
                    guard pt.x.isFinite, pt.y.isFinite else { return nil }
                    let topX = pad + CGFloat(pt.x - worldTransform.minX) * totalScale
                    let topY = cursorY + CGFloat(pt.y - worldTransform.minY) * totalScale
                    return CGPoint(x: topX, y: totalHeight - topY)
                }
                guard cgPts.count >= 2 else { continue }
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: CGFloat(alpha)))
                ctx.setLineWidth(lw)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.beginPath()
                ctx.move(to: cgPts[0])
                for pt in cgPts.dropFirst() { ctx.addLine(to: pt) }
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }

    // MARK: - Layout

    private struct LaidOutNode {
        let node: BoardNode
        let rect: CGRect
    }

    private struct TopDownLayoutOutput {
        let nodes: [LaidOutNode]
        let freeformTransform: (minX: Double, minY: Double, scale: CGFloat)?
    }

    private static func resolveTopDownLayout(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        contentWidth: CGFloat
    ) -> TopDownLayoutOutput {
        switch document.mode {
        case .freeform:
            let visible = document.nodes.filter {
                if case .paletteStrip = $0.kind { return false }
                return $0.frame.x.isFinite && $0.frame.y.isFinite
                    && $0.frame.width.isFinite && $0.frame.height.isFinite
                    && $0.frame.width > 0 && $0.frame.height > 0
            }
            guard !visible.isEmpty else { return TopDownLayoutOutput(nodes: [], freeformTransform: nil) }
            let minX = visible.map { $0.frame.minX }.min() ?? 0
            let minY = visible.map { $0.frame.minY }.min() ?? 0
            let maxX = visible.map { $0.frame.maxX }.max() ?? Double(contentWidth)
            let spanW = max(320, maxX - minX)
            let scale = min(1.0, Double(contentWidth) / spanW)
            let nodes = visible.map { node in
                let rect = CGRect(
                    x: (node.frame.x - minX) * scale,
                    y: (node.frame.y - minY) * scale,
                    width: max(80, node.frame.width * scale),
                    height: max(44, node.frame.height * scale)
                )
                return LaidOutNode(node: node, rect: rect)
            }
            return TopDownLayoutOutput(nodes: nodes, freeformTransform: (minX, minY, CGFloat(scale)))

        case .autoEditorial(let cfg):
            let ordered = document.nodes.sorted { $0.editorialOrder < $1.editorialOrder }
            let cols = max(2, min(5, cfg.columns))
            let gap = CGFloat(max(10, min(28, cfg.spacing.isFinite ? cfg.spacing : 16)))
            let colW = floor((contentWidth - gap * CGFloat(cols - 1)) / CGFloat(cols))
            var result: [LaidOutNode] = []
            var cursorY: CGFloat = 0
            var colHeights = [CGFloat](repeating: 0, count: cols)

            func flushColumns() {
                let maxH = colHeights.max() ?? cursorY
                cursorY = maxH
                colHeights = [CGFloat](repeating: cursorY, count: cols)
            }

            for node in ordered {
                switch node.kind {
                case .paletteStrip:
                    continue

                case .note:
                    flushColumns()
                    let h: CGFloat = 112
                    result.append(LaidOutNode(node: node, rect: CGRect(x: 0, y: cursorY, width: contentWidth, height: h)))
                    cursorY += h + gap
                    colHeights = [CGFloat](repeating: cursorY, count: cols)

                case .groupFrame:
                    flushColumns()
                    if cursorY > 0 { cursorY += 10 }
                    let h: CGFloat = 46
                    result.append(LaidOutNode(node: node, rect: CGRect(x: 0, y: cursorY, width: contentWidth, height: h)))
                    cursorY += h + gap
                    colHeights = [CGFloat](repeating: cursorY, count: cols)

                case .assetRef(let assetID, _, let weight, _):
                    let rawRatio = assetsByID[assetID]?.aspectRatio ?? 1.25
                    let aspect = CGFloat(max(0.55, min(2.0, (rawRatio.isFinite && rawRatio > 0) ? rawRatio : 1.25)))
                    let span = (weight >= 2 && cols >= 2) ? 2 : 1
                    if span == 2 {
                        // Pick adjacent column pair with lowest max height
                        var bestStart = 0
                        var bestY = CGFloat.greatestFiniteMagnitude
                        for start in 0...(cols - 2) {
                            let y = max(colHeights[start], colHeights[start + 1])
                            if y < bestY {
                                bestY = y
                                bestStart = start
                            }
                        }
                        let cardW = colW * 2 + gap
                        let cardH = max(180, min(520, floor(cardW / aspect)))
                        let x = CGFloat(bestStart) * (colW + gap)
                        result.append(LaidOutNode(node: node, rect: CGRect(x: x, y: bestY, width: cardW, height: cardH)))
                        let nextY = bestY + cardH + gap
                        colHeights[bestStart] = nextY
                        colHeights[bestStart + 1] = nextY
                    } else {
                        let col = colHeights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
                        let y = colHeights[col]
                        let cardH = max(130, min(390, floor(colW / aspect)))
                        let x = CGFloat(col) * (colW + gap)
                        result.append(LaidOutNode(node: node, rect: CGRect(x: x, y: y, width: colW, height: cardH)))
                        colHeights[col] = y + cardH + gap
                    }
                }
            }
            return TopDownLayoutOutput(nodes: result, freeformTransform: nil)
        }
    }

    // MARK: - Drawing Utilities

    private static func drawConnector(
        ctx: CGContext,
        connector: BoardConnector,
        from: CGRect,
        fromNode: BoardNode,
        to: CGRect,
        toNode: BoardNode
    ) {
        func endpoint(rect: CGRect, node: BoardNode, anchor: ConnectorAnchor, normalized: BoardPoint?, towards other: CGRect) -> CGPoint {
            let unrotated: CGPoint
            if let normalized, normalized.x.isFinite, normalized.y.isFinite {
                var nx = max(0.0, min(1.0, normalized.x))
                var ny = max(0.0, min(1.0, normalized.y))
                if node.flipHorizontal { nx = 1.0 - nx }
                if node.flipVertical { ny = 1.0 - ny }
                // Convert top-down normalized y into CG bottom-left rect y
                unrotated = CGPoint(x: rect.minX + rect.width * CGFloat(nx), y: rect.maxY - rect.height * CGFloat(ny))
            } else {
                let resolved: ConnectorAnchor
                if anchor == .auto {
                    let dx = other.midX - rect.midX
                    let dy = other.midY - rect.midY
                    if abs(dx) >= abs(dy) {
                        resolved = dx >= 0 ? .trailing : .leading
                    } else {
                        resolved = dy >= 0 ? .top : .bottom
                    }
                } else {
                    resolved = anchor
                }
                unrotated = switch resolved {
                case .top: CGPoint(x: rect.midX, y: rect.maxY)
                case .bottom: CGPoint(x: rect.midX, y: rect.minY)
                case .leading: CGPoint(x: rect.minX, y: rect.midY)
                case .trailing: CGPoint(x: rect.maxX, y: rect.midY)
                case .auto: CGPoint(x: rect.midX, y: rect.midY)
                }
            }
            let rotDeg = node.rotationDegrees.isFinite ? node.rotationDegrees : 0
            guard abs(rotDeg) > 0.1 else { return unrotated }
            let rad = CGFloat(-rotDeg * .pi / 180.0)
            let dx = unrotated.x - rect.midX
            let dy = unrotated.y - rect.midY
            return CGPoint(
                x: rect.midX + dx * cos(rad) - dy * sin(rad),
                y: rect.midY + dx * sin(rad) + dy * cos(rad)
            )
        }

        let start = endpoint(rect: from, node: fromNode, anchor: connector.fromAnchor, normalized: connector.fromNormalizedPoint, towards: to)
        let end = endpoint(rect: to, node: toNode, anchor: connector.toAnchor, normalized: connector.toNormalizedPoint, towards: from)
        let rgb = hexToRGB(connector.colorHex) ?? (0.36, 0.40, 0.45)
        let strokeColor = CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)

        ctx.saveGState()
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if connector.dashed { ctx.setLineDash(phase: 0, lengths: [6, 5]) }

        let midX = (start.x + end.x) * 0.5
        ctx.beginPath()
        ctx.move(to: start)
        switch connector.style {
        case .straight:
            ctx.addLine(to: end)
        case .elbow:
            ctx.addLine(to: CGPoint(x: midX, y: start.y))
            ctx.addLine(to: CGPoint(x: midX, y: end.y))
            ctx.addLine(to: end)
        case .curved:
            let c1 = CGPoint(x: midX, y: start.y)
            let c2 = CGPoint(x: midX, y: end.y)
            ctx.addCurve(to: end, control1: c1, control2: c2)
        }
        ctx.strokePath()

        // Arrowhead
        ctx.setLineDash(phase: 0, lengths: [])
        let tangentSrc = connector.style == .straight ? start : CGPoint(x: midX, y: end.y)
        let angle = atan2(end.y - tangentSrc.y, end.x - tangentSrc.x)
        let arrowLen: CGFloat = 9
        let spread: CGFloat = .pi / 6.5
        ctx.beginPath()
        ctx.move(to: CGPoint(x: end.x - arrowLen * cos(angle - spread), y: end.y - arrowLen * sin(angle - spread)))
        ctx.addLine(to: end)
        ctx.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + spread), y: end.y - arrowLen * sin(angle + spread)))
        ctx.strokePath()

        if connector.toNormalizedPoint != nil {
            let dot = CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(strokeColor)
            ctx.fillEllipse(in: dot)
        }
        ctx.restoreGState()
    }

    private static func nodeLayerPriority(_ kind: BoardNodeKind) -> Int {
        switch kind {
        case .groupFrame: 0
        case .assetRef: 1
        case .note: 2
        case .paletteStrip: 3
        }
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func aspectFillRect(imageWidth: CGFloat, imageHeight: CGFloat, filling target: CGRect) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return target }
        let scale = max(target.width / imageWidth, target.height / imageHeight)
        let w = imageWidth * scale
        let h = imageHeight * scale
        return CGRect(
            x: target.midX - w * 0.5,
            y: target.midY - h * 0.5,
            width: w,
            height: h
        )
    }

    private enum FontWeight { case regular, medium, semibold, bold }

    private static func drawText(
        _ string: String,
        in rect: CGRect,
        fontSize: CGFloat,
        weight: FontWeight,
        color: CGColor,
        alignment: CTTextAlignment = .left,
        ctx: CGContext
    ) {
        let fontName: CFString = switch weight {
        case .regular: "PingFangSC-Regular" as CFString
        case .medium: "PingFangSC-Medium" as CFString
        case .semibold: "PingFangSC-Semibold" as CFString
        case .bold: "PingFangSC-Semibold" as CFString
        }
        let font = CTFontCreateWithName(fontName, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        guard let attrStr = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attrStr)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let drawX: CGFloat = alignment == .right ? max(rect.minX, rect.maxX - lineWidth) : rect.minX
        let baselineY = rect.minY + (rect.height - fontSize) * 0.5 + 2
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: drawX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawWrappedText(
        _ string: String,
        in rect: CGRect,
        fontSize: CGFloat,
        color: CGColor,
        ctx: CGContext
    ) {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        guard let attrStr = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary) else {
            return
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    private static func groupFillColor(tint: GroupTint, dark: Bool) -> CGColor {
        let alpha: CGFloat = dark ? 0.16 : 0.08
        switch tint {
        case .neutral: return dark ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.06) : CGColor(red: 0, green: 0, blue: 0, alpha: 0.04)
        case .sand: return CGColor(red: 0.84, green: 0.72, blue: 0.55, alpha: alpha)
        case .sage: return CGColor(red: 0.51, green: 0.65, blue: 0.54, alpha: alpha)
        case .slate: return CGColor(red: 0.45, green: 0.54, blue: 0.68, alpha: alpha)
        case .terracotta: return CGColor(red: 0.80, green: 0.44, blue: 0.34, alpha: alpha)
        case .ocean: return CGColor(red: 0.22, green: 0.56, blue: 0.78, alpha: alpha)
        }
    }

    private static func noteFillColor(style: NoteStyle, dark: Bool) -> CGColor {
        switch style {
        case .paper: return dark ? CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1.0) : CGColor(red: 1.0, green: 0.996, blue: 0.98, alpha: 1.0)
        case .ink: return CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
        case .warm: return dark ? CGColor(red: 0.25, green: 0.20, blue: 0.15, alpha: 1.0) : CGColor(red: 0.98, green: 0.94, blue: 0.87, alpha: 1.0)
        case .sage: return dark ? CGColor(red: 0.16, green: 0.23, blue: 0.18, alpha: 1.0) : CGColor(red: 0.91, green: 0.95, blue: 0.91, alpha: 1.0)
        case .slate: return dark ? CGColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1.0) : CGColor(red: 0.91, green: 0.94, blue: 0.98, alpha: 1.0)
        }
    }

    private static func hexToRGB(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return (
            r: CGFloat((value >> 16) & 0xFF) / 255.0,
            g: CGFloat((value >> 8) & 0xFF) / 255.0,
            b: CGFloat(value & 0xFF) / 255.0
        )
    }
}

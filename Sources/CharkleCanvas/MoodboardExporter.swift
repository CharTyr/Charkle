import AppKit
import CharkleCore
import CoreGraphics
import SwiftUI

public enum MoodboardExportFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }
}

public nonisolated struct MoodboardExportOptions: Sendable {
    public var scale: CGFloat
    public var includeAnnotations: Bool
    public var includePaletteStrip: Bool
    public var darkAppearance: Bool
    public var padding: CGFloat

    public init(
        scale: CGFloat = 2.0,
        includeAnnotations: Bool = true,
        includePaletteStrip: Bool = true,
        darkAppearance: Bool = false,
        padding: CGFloat = 40
    ) {
        self.scale = scale
        self.includeAnnotations = includeAnnotations
        self.includePaletteStrip = includePaletteStrip
        self.darkAppearance = darkAppearance
        self.padding = padding
    }
}

/// High-DPI 2× Retina exporter rendering an entire `MoodboardDocument` (nodes, palette strip,
/// connectors, and vector ink strokes) to PNG/JPG on disk or directly onto `NSPasteboard`
/// for instant `⌘V` into Figma / Keynote.
public enum MoodboardExporter {
    /// Preloads all referenced board asset thumbnails concurrently (bounded to 6 parallel decodes)
    /// into `loader` so off-screen or freshly opened cards export with crisp pixels without serial stalls.
    public static func preloadImages(
        for document: MoodboardDocument,
        loader: ThumbnailImageLoader
    ) async {
        var uniqueIDs: [UUID] = []
        var seen = Set<UUID>()
        for id in document.referencedAssetIDs where seen.insert(id).inserted {
            if loader.cachedCGImage(for: id, tier: .preview1400) == nil {
                uniqueIDs.append(id)
            }
        }
        guard !uniqueIDs.isEmpty else { return }

        let maxConcurrent = 6
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            let initialBatch = min(maxConcurrent, uniqueIDs.count)
            while nextIndex < initialBatch {
                let assetID = uniqueIDs[nextIndex]
                nextIndex += 1
                group.addTask {
                    await Self.preloadSingleAsset(assetID, loader: loader)
                }
            }
            for await _ in group {
                if nextIndex < uniqueIDs.count {
                    let assetID = uniqueIDs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await Self.preloadSingleAsset(assetID, loader: loader)
                    }
                }
            }
        }
    }

    private static func preloadSingleAsset(_ assetID: UUID, loader: ThumbnailImageLoader) async {
        let preview = await loader.loadCGImage(for: assetID, tier: .preview1400)
        if preview == nil && loader.cachedCGImage(for: assetID, tier: .grid520) == nil {
            _ = await loader.loadCGImage(for: assetID, tier: .grid520)
        }
    }

    public static func renderImage(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions(),
        resolveImage: ((UUID) -> CGImage?)? = nil
    ) -> NSImage? {
        guard let rep = renderBitmapRep(
            document: document,
            assetsByID: assetsByID,
            loader: loader,
            containerWidth: containerWidth,
            options: options,
            resolveImage: resolveImage
        ) else {
            return nil
        }
        let finalImage = NSImage(size: rep.size)
        finalImage.addRepresentation(rep)
        return finalImage
    }

    public static func renderImageAsync(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions(),
        resolveImage: ((UUID) -> CGImage?)? = nil
    ) async -> NSImage? {
        await preloadImages(for: document, loader: loader)
        return renderImage(
            document: document,
            assetsByID: assetsByID,
            loader: loader,
            containerWidth: containerWidth,
            options: options,
            resolveImage: resolveImage
        )
    }

    private static func renderBitmapRep(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions(),
        resolveImage: ((UUID) -> CGImage?)? = nil
    ) -> NSBitmapImageRep? {
        let resolvedFrames: [UUID: BoardRect]
        switch document.mode {
        case .autoEditorial(let cfg):
            resolvedFrames = EditorialLayoutSolver.solve(
                nodes: document.nodes,
                config: cfg,
                containerWidth: containerWidth,
                assetsByID: assetsByID
            ).frames
        case .freeform:
            resolvedFrames = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0.frame) })
        }

        // Compute tight bounding box across all nodes (including rotated corners) and ink strokes
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for node in document.nodes {
            guard let rect = resolvedFrames[node.id],
                  rect.x.isFinite, rect.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { continue }
            let rot = node.rotationDegrees.isFinite ? node.rotationDegrees : 0
            if abs(rot) > 0.1 {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let corners = [
                    CGPoint(x: rect.minX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY),
                    CGPoint(x: rect.maxX, y: rect.maxY)
                ]
                for corner in corners {
                    let rotated = ConnectorGeometry.rotatedPoint(corner, around: center, degrees: rot)
                    minX = min(minX, Double(rotated.x))
                    minY = min(minY, Double(rotated.y))
                    maxX = max(maxX, Double(rotated.x))
                    maxY = max(maxY, Double(rotated.y))
                }
            } else {
                minX = min(minX, rect.minX)
                minY = min(minY, rect.minY)
                maxX = max(maxX, rect.maxX)
                maxY = max(maxY, rect.maxY)
            }
        }
        if options.includeAnnotations {
            for stroke in document.inkStrokes {
                let lw = stroke.lineWidth.isFinite ? max(1, stroke.lineWidth) : 3.0
                for pt in stroke.points where pt.x.isFinite && pt.y.isFinite {
                    minX = min(minX, pt.x - lw)
                    minY = min(minY, pt.y - lw)
                    maxX = max(maxX, pt.x + lw)
                    maxY = max(maxY, pt.y + lw)
                }
            }
        }

        if !minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite || maxX <= minX || maxY <= minY {
            minX = 0
            minY = 0
            maxX = 960
            maxY = 640
        }

        let headerHeight: CGFloat = (options.includePaletteStrip && !document.extractedPalette.isEmpty) ? 72 : 44
        let pad = options.padding.isFinite ? max(16, min(160, options.padding)) : 40
        let rawContentW = max(1, CGFloat(maxX - minX))
        let rawContentH = max(1, CGFloat(maxY - minY))
        let maxCanvasDim: CGFloat = 4800

        // Downscale uniformly when content exceeds max canvas size instead of silently clipping right/bottom edges
        let maxAvailableContentW = max(200, maxCanvasDim - pad * 2)
        let maxAvailableContentH = max(200, maxCanvasDim - pad * 2 - headerHeight)
        let contentScale = min(1.0, min(maxAvailableContentW / rawContentW, maxAvailableContentH / rawContentH))
        let scaledContentW = rawContentW * contentScale
        let scaledContentH = rawContentH * contentScale

        let canvasW = max(640, min(maxCanvasDim, ceil(scaledContentW + pad * 2)))
        let canvasH = max(420, min(maxCanvasDim, ceil(scaledContentH + pad * 2 + headerHeight)))

        // Bound total pixel area to <= 36M pixels (~144MB RGBA) to prevent huge-canvas OOM
        let requestedScale = options.scale.isFinite ? max(1.0, min(3.0, options.scale)) : 2.0
        let maxPixelBudget: CGFloat = 36_000_000
        let effectiveScale = min(requestedScale, sqrt(maxPixelBudget / max(1, canvasW * canvasH)))
        let pixelW = max(1, Int((canvasW * effectiveScale).rounded()))
        let pixelH = max(1, Int((canvasH * effectiveScale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: canvasW, height: canvasH)

        NSGraphicsContext.saveGraphicsState()
        guard let baseNsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        let ctx = baseNsCtx.cgContext
        // Flip raw CGContext into top-left coordinates matching SwiftUI canvas coordinates,
        // and wrap it in a flipped NSGraphicsContext so NSString.draw renders glyphs upright.
        ctx.translateBy(x: 0, y: canvasH)
        ctx.scaleBy(x: 1, y: -1)
        let flippedNsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = flippedNsCtx
        defer {
            _ = baseNsCtx
            NSGraphicsContext.restoreGraphicsState()
        }

        // Neutral gallery ground
        let bgColor = options.darkAppearance ? NSColor.charkleHex("#141518") : NSColor.charkleHex("#F5F5F6")
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        let inkPrimary = options.darkAppearance ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.86)
        let inkSecondary = options.darkAppearance ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.50)

        // Draw title + optional board palette strip
        drawHeader(
            ctx: ctx,
            document: document,
            canvasWidth: canvasW,
            padding: pad,
            includePalette: options.includePaletteStrip,
            inkPrimary: inkPrimary,
            inkSecondary: inkSecondary
        )

        ctx.saveGState()
        ctx.translateBy(x: pad, y: pad + headerHeight)
        if contentScale < 0.9999 {
            ctx.scaleBy(x: contentScale, y: contentScale)
        }
        ctx.translateBy(x: -CGFloat(minX), y: -CGFloat(minY))

        // Draw nodes sorted by zIndex (group frames first)
        let orderedNodes = document.nodes.sorted { lhs, rhs in
            let lGroup = if case .groupFrame = lhs.kind { true } else { false }
            let rGroup = if case .groupFrame = rhs.kind { true } else { false }
            if lGroup != rGroup { return lGroup }
            return lhs.zIndex < rhs.zIndex
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })

        for node in orderedNodes {
            guard let baseRect = resolvedFrames[node.id],
                  baseRect.x.isFinite, baseRect.y.isFinite,
                  baseRect.width.isFinite, baseRect.height.isFinite,
                  baseRect.width > 0, baseRect.height > 0 else { continue }
            let drawRect = CGRect(
                x: CGFloat(baseRect.x),
                y: CGFloat(baseRect.y),
                width: CGFloat(baseRect.width),
                height: CGFloat(baseRect.height)
            )
            drawNode(
                ctx: ctx,
                node: node,
                rect: drawRect,
                extractedPalette: document.extractedPalette,
                assetsByID: assetsByID,
                loader: loader,
                darkAppearance: options.darkAppearance,
                resolveImage: resolveImage
            )
        }

        // Connectors & Freehand Ink Strokes
        if options.includeAnnotations {
            for connector in document.connectors {
                guard let fromRect = resolvedFrames[connector.fromNodeID],
                      let toRect = resolvedFrames[connector.toNodeID] else { continue }
                let fromNode = nodesByID[connector.fromNodeID]
                let toNode = nodesByID[connector.toNodeID]
                drawConnector(
                    ctx: ctx,
                    connector: connector,
                    fromRect: fromRect.cgRect,
                    fromNode: fromNode,
                    toRect: toRect.cgRect,
                    toNode: toNode,
                    darkAppearance: options.darkAppearance
                )
            }

            for stroke in document.inkStrokes where stroke.points.count >= 2 {
                drawInkStroke(ctx: ctx, stroke: stroke, offsetX: 0, offsetY: 0)
            }
        }

        ctx.restoreGState()
        return rep
    }

    @discardableResult
    public static func copyToPasteboard(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions(),
        resolveImage: ((UUID) -> CGImage?)? = nil
    ) -> Bool {
        guard let rep = renderBitmapRep(
            document: document,
            assetsByID: assetsByID,
            loader: loader,
            containerWidth: containerWidth,
            options: options,
            resolveImage: resolveImage
        ),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        // Skip expensive 100MB+ uncompressed TIFF serialization on huge canvases; PNG covers Figma/Keynote/macOS apps.
        if rep.pixelsWide * rep.pixelsHigh <= 4_000_000, let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        return true
    }

    public static func exportToFile(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        url: URL,
        format: MoodboardExportFormat,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions(),
        resolveImage: ((UUID) -> CGImage?)? = nil
    ) throws {
        guard let rep = renderBitmapRep(
            document: document,
            assetsByID: assetsByID,
            loader: loader,
            containerWidth: containerWidth,
            options: options,
            resolveImage: resolveImage
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data: Data? = switch format {
        case .png:
            rep.representation(using: .png, properties: [:])
        case .jpeg:
            rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        }
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - CoreGraphics Drawing Primitives

    private static func drawHeader(
        ctx: CGContext,
        document: MoodboardDocument,
        canvasWidth: CGFloat,
        padding: CGFloat,
        includePalette: Bool,
        inkPrimary: NSColor,
        inkSecondary: NSColor
    ) {
        var paletteReserveW: CGFloat = 0
        if includePalette, !document.extractedPalette.isEmpty {
            let swatches = Array(document.extractedPalette.prefix(7))
            let swatchW: CGFloat = 28
            let swatchH: CGFloat = 20
            let gap: CGFloat = 6
            let totalW = CGFloat(swatches.count) * swatchW + CGFloat(max(0, swatches.count - 1)) * gap
            paletteReserveW = totalW + 16
            var x = canvasWidth - padding - totalW
            let y = padding * 0.65 + 4
            for color in swatches {
                let r = CGRect(x: x, y: y, width: swatchW, height: swatchH)
                let path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(NSColor.charkleHex(color.hex).cgColor)
                ctx.fillPath()
                x += swatchW + gap
            }
        }

        let maxTitleW = max(120, canvasWidth - padding * 2 - paletteReserveW)
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineBreakMode = .byTruncatingTail
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: inkPrimary,
            .paragraphStyle: titleParagraph
        ]
        NSString(string: document.title).draw(
            in: CGRect(x: padding, y: padding * 0.65, width: maxTitleW, height: 26),
            withAttributes: titleAttr
        )

        if !document.subtitle.isEmpty {
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: inkSecondary,
                .paragraphStyle: titleParagraph
            ]
            NSString(string: document.subtitle).draw(
                in: CGRect(x: padding, y: padding * 0.65 + 26, width: maxTitleW, height: 18),
                withAttributes: subAttr
            )
        }
    }

    private static func drawNode(
        ctx: CGContext,
        node: BoardNode,
        rect: CGRect,
        extractedPalette: [LabColor],
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        darkAppearance: Bool,
        resolveImage: ((UUID) -> CGImage?)?
    ) {
        ctx.saveGState()
        let rot = node.rotationDegrees.isFinite ? node.rotationDegrees : 0
        if abs(rot) > 0.1 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: CGFloat(rot * .pi / 180.0))
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }

        switch node.kind {
        case .assetRef(let assetID, _, _, _):
            let clipPath = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()

            let resolvedBaseCG: CGImage? = {
                if let direct = resolveImage?(assetID) { return direct }
                if let cachedCG = loader.cachedCGImage(for: assetID, tier: .preview1400)
                    ?? loader.cachedCGImage(for: assetID, tier: .grid520) {
                    return cachedCG
                }
                if let nsImg = loader.cachedOriginalImage(for: assetID),
                   let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    return cg
                }
                return nil
            }()

            if let baseCG = resolvedBaseCG {
                let cgImg: CGImage = {
                    guard case .assetRef(_, let crop?, _, _) = node.kind,
                          crop != .full, crop.width > 0.04, crop.height > 0.04 else {
                        return baseCG
                    }
                    let clamped = crop.clamped()
                    let pixelRect = CGRect(
                        x: (clamped.x * Double(baseCG.width)).rounded(.down),
                        y: (clamped.y * Double(baseCG.height)).rounded(.down),
                        width: max(4, (clamped.width * Double(baseCG.width)).rounded()),
                        height: max(4, (clamped.height * Double(baseCG.height)).rounded())
                    ).intersection(CGRect(x: 0, y: 0, width: baseCG.width, height: baseCG.height))
                    if pixelRect.width >= 4, pixelRect.height >= 4, let cropped = baseCG.cropping(to: pixelRect) {
                        return cropped
                    }
                    return baseCG
                }()
                // Aspect-fill draw (compensate for flipped CGContext so images stay upright)
                let imgAspect = CGFloat(cgImg.width) / max(1, CGFloat(cgImg.height))
                let boxAspect = rect.width / max(1, rect.height)
                var drawR = rect
                if imgAspect > boxAspect {
                    let scaledW = rect.height * imgAspect
                    drawR = CGRect(x: rect.midX - scaledW * 0.5, y: rect.minY, width: scaledW, height: rect.height)
                } else {
                    let scaledH = rect.width / imgAspect
                    drawR = CGRect(x: rect.minX, y: rect.midY - scaledH * 0.5, width: rect.width, height: scaledH)
                }
                ctx.saveGState()
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.scaleBy(
                    x: node.flipHorizontal ? -1 : 1,
                    y: node.flipVertical ? -1 : 1
                )
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
                ctx.translateBy(x: drawR.minX, y: drawR.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: drawR.width, height: drawR.height))
                ctx.restoreGState()
            } else {
                let asset = assetsByID[assetID]
                let hex = asset?.dominantColors.first?.hex ?? (darkAppearance ? "#2B2F36" : "#DCE0E6")
                ctx.setFillColor(NSColor.charkleHex(hex).cgColor)
                ctx.fill(rect)
                if let title = asset?.title {
                    let attr: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: Color.charkleIsLightHex(hex) ? NSColor.black.withAlphaComponent(0.72) : NSColor.white.withAlphaComponent(0.86)
                    ]
                    NSString(string: title).draw(in: rect.insetBy(dx: 12, dy: 12), withAttributes: attr)
                }
            }

        case .note(let title, let text, let style, let fontSize):
            let (bg, fg) = noteColors(for: style)
            let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(bg.cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(fg.withAlphaComponent(0.14).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()

            let safeFontSize = fontSize.isFinite ? max(10, min(48, fontSize)) : 14
            let innerW = max(12, rect.width - 28)
            var textY = rect.minY + 14
            if let title, !title.isEmpty {
                let titleAttr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: CGFloat(max(13, safeFontSize)), weight: .semibold),
                    .foregroundColor: fg
                ]
                NSString(string: title).draw(in: CGRect(x: rect.minX + 14, y: textY, width: innerW, height: 24), withAttributes: titleAttr)
                textY += 24
            }
            let bodyAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: CGFloat(max(11, safeFontSize - 1)), weight: .regular),
                .foregroundColor: fg.withAlphaComponent(0.86)
            ]
            NSString(string: text).draw(in: CGRect(x: rect.minX + 14, y: textY, width: innerW, height: max(20, rect.maxY - textY - 12)), withAttributes: bodyAttr)

        case .groupFrame(let title, let tint):
            let tintColor = groupTintNSColor(tint)
            let path = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(tintColor.withAlphaComponent(darkAppearance ? 0.14 : 0.10).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(tintColor.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: darkAppearance ? NSColor.white.withAlphaComponent(0.88) : NSColor.black.withAlphaComponent(0.78),
                .paragraphStyle: paragraph
            ]
            NSString(string: title).draw(
                in: CGRect(x: rect.minX + 14, y: rect.minY + 10, width: max(24, rect.width - 28), height: 20),
                withAttributes: attr
            )

        case .paletteStrip(let colors, let autoSync):
            let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(path)
            ctx.clip()
            let activeColors = (autoSync && !extractedPalette.isEmpty) ? extractedPalette : colors
            let list = activeColors.isEmpty ? [LabColor.fromHex("#808080")] : activeColors
            let segW = rect.width / CGFloat(list.count)
            for (idx, color) in list.enumerated() {
                let r = CGRect(x: rect.minX + CGFloat(idx) * segW, y: rect.minY, width: segW + 0.5, height: rect.height)
                ctx.setFillColor(NSColor.charkleHex(color.hex).cgColor)
                ctx.fill(r)
                let attr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: Color.charkleIsLightHex(color.hex) ? NSColor.black.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.88)
                ]
                NSString(string: color.hex.uppercased()).draw(
                    in: CGRect(x: r.minX + 8, y: r.maxY - 20, width: max(12, segW - 12), height: 16),
                    withAttributes: attr
                )
            }
        }

        ctx.restoreGState()
    }

    private static func drawConnector(
        ctx: CGContext,
        connector: BoardConnector,
        fromRect: CGRect,
        fromNode: BoardNode?,
        toRect: CGRect,
        toNode: BoardNode?,
        darkAppearance: Bool
    ) {
        let (start, end, c1, c2) = ConnectorGeometry.resolvePathPoints(
            fromRect: fromRect,
            fromAnchor: connector.fromAnchor,
            fromNormalizedPoint: connector.fromNormalizedPoint,
            fromRotationDegrees: fromNode?.rotationDegrees ?? 0,
            fromFlipHorizontal: fromNode?.flipHorizontal ?? false,
            fromFlipVertical: fromNode?.flipVertical ?? false,
            toRect: toRect,
            toAnchor: connector.toAnchor,
            toNormalizedPoint: connector.toNormalizedPoint,
            toRotationDegrees: toNode?.rotationDegrees ?? 0,
            toFlipHorizontal: toNode?.flipHorizontal ?? false,
            toFlipVertical: toNode?.flipVertical ?? false,
            style: connector.style
        )
        ctx.saveGState()
        let strokeColor = NSColor.charkleHex(connector.colorHex)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(2.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if connector.dashed {
            ctx.setLineDash(phase: 0, lengths: [6, 5])
        }

        ctx.beginPath()
        ctx.move(to: start)
        switch connector.style {
        case .curved:
            ctx.addCurve(to: end, control1: c1, control2: c2)
        case .elbow:
            let midX = (start.x + end.x) * 0.5
            ctx.addLine(to: CGPoint(x: midX, y: start.y))
            ctx.addLine(to: CGPoint(x: midX, y: end.y))
            ctx.addLine(to: end)
        case .straight:
            ctx.addLine(to: end)
        }
        ctx.strokePath()

        // Arrowhead
        ctx.setLineDash(phase: 0, lengths: [])
        let tangentSource: CGPoint = switch connector.style {
        case .curved: c2
        case .elbow: CGPoint(x: (start.x + end.x) * 0.5, y: end.y)
        case .straight: start
        }
        let angle = atan2(end.y - tangentSource.y, end.x - tangentSource.x)
        let arrowLen: CGFloat = 10
        let spread: CGFloat = .pi / 6.5
        let p1 = CGPoint(x: end.x - arrowLen * cos(angle - spread), y: end.y - arrowLen * sin(angle - spread))
        let p2 = CGPoint(x: end.x - arrowLen * cos(angle + spread), y: end.y - arrowLen * sin(angle + spread))
        ctx.beginPath()
        ctx.move(to: p1)
        ctx.addLine(to: end)
        ctx.addLine(to: p2)
        ctx.strokePath()

        if connector.toNormalizedPoint != nil {
            // Precision pinpoint callout target ring on the object
            let halo = CGRect(x: end.x - 8, y: end.y - 8, width: 16, height: 16)
            ctx.setFillColor(strokeColor.withAlphaComponent(0.20).cgColor)
            ctx.fillEllipse(in: halo)
            let dot = CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(strokeColor.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: dot)
        }

        // Connector midpoint label pill
        if let rawLabel = connector.label?.trimmingCharacters(in: .whitespacesAndNewlines), !rawLabel.isEmpty {
            let mid = ConnectorGeometry.midpoint(start: start, end: end, c1: c1, c2: c2, style: connector.style)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: darkAppearance ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.86)
            ]
            let nsLabel = NSString(string: rawLabel)
            let textSize = nsLabel.size(withAttributes: labelAttrs)
            let pillW = ceil(textSize.width) + 16
            let pillH = ceil(textSize.height) + 6
            let pillRect = CGRect(x: mid.x - pillW * 0.5, y: mid.y - pillH * 0.5, width: pillW, height: pillH)
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillH * 0.5, cornerHeight: pillH * 0.5, transform: nil)
            let pillBg = darkAppearance ? NSColor.charkleHex("#23262C") : NSColor.charkleHex("#FFFFFF")
            ctx.addPath(pillPath)
            ctx.setFillColor(pillBg.cgColor)
            ctx.fillPath()
            ctx.addPath(pillPath)
            ctx.setStrokeColor(strokeColor.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(0.9)
            ctx.strokePath()
            nsLabel.draw(
                at: NSPoint(x: pillRect.minX + 8, y: pillRect.minY + 3),
                withAttributes: labelAttrs
            )
        }
        ctx.restoreGState()
    }

    private static func drawInkStroke(ctx: CGContext, stroke: InkStroke, offsetX: CGFloat, offsetY: CGFloat) {
        let pts: [CGPoint] = stroke.points.compactMap { pt in
            guard pt.x.isFinite, pt.y.isFinite else { return nil }
            return CGPoint(x: CGFloat(pt.x) + offsetX, y: CGFloat(pt.y) + offsetY)
        }
        guard pts.count >= 2 else { return }
        let safeOpacity = stroke.opacity.isFinite ? max(0.05, min(1.0, stroke.opacity)) : 0.92
        let safeWidth = stroke.lineWidth.isFinite ? max(0.5, min(64, stroke.lineWidth)) : 3.0
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.charkleHex(stroke.colorHex).withAlphaComponent(CGFloat(safeOpacity)).cgColor)
        ctx.setLineWidth(CGFloat(safeWidth))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: pts[0])
        if pts.count == 2 {
            ctx.addLine(to: pts[1])
        } else {
            for i in 1..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) * 0.5, y: (pts[i].y + pts[i + 1].y) * 0.5)
                ctx.addQuadCurve(to: mid, control: pts[i])
            }
            if let last = pts.last {
                ctx.addLine(to: last)
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func noteColors(for style: NoteStyle) -> (NSColor, NSColor) {
        switch style {
        case .paper: (NSColor.charkleHex("#FFFFFF"), NSColor.charkleHex("#1D1F23"))
        case .ink: (NSColor.charkleHex("#1D1F24"), NSColor.charkleHex("#F1F2F4"))
        case .warm: (NSColor.charkleHex("#F7F0E4"), NSColor.charkleHex("#392F22"))
        case .sage: (NSColor.charkleHex("#E8F0EA"), NSColor.charkleHex("#203227"))
        case .slate: (NSColor.charkleHex("#E9EEF3"), NSColor.charkleHex("#1F2B36"))
        }
    }

    private static func groupTintNSColor(_ tint: GroupTint) -> NSColor {
        switch tint {
        case .neutral: NSColor.charkleHex("#7D838B")
        case .sand: NSColor.charkleHex("#B5956B")
        case .sage: NSColor.charkleHex("#6B8E76")
        case .slate: NSColor.charkleHex("#627A94")
        case .terracotta: NSColor.charkleHex("#BA6B55")
        case .ocean: NSColor.charkleHex("#4D7E97")
        }
    }
}

/// Shared connector path routing geometry used by both live SwiftUI Canvas and High-DPI Exporter.
public nonisolated enum ConnectorGeometry {
    /// Rotates a point clockwise around `center` in y-down canvas coordinates.
    public static func rotatedPoint(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        guard degrees.isFinite, abs(degrees) > 0.05 else { return point }
        let rad = CGFloat(degrees * .pi / 180.0)
        let cosR = cos(rad)
        let sinR = sin(rad)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cosR - dy * sinR,
            y: center.y + dx * sinR + dy * cosR
        )
    }

    /// Tests whether a world point lies inside a possibly rotated node rectangle.
    public static func containsPoint(_ worldPoint: CGPoint, in rect: CGRect, rotationDegrees: Double) -> Bool {
        let local = rotatedPoint(worldPoint, around: CGPoint(x: rect.midX, y: rect.midY), degrees: -rotationDegrees)
        return rect.contains(local)
    }

    public static func anchorPoint(
        for rect: CGRect,
        anchor: ConnectorAnchor,
        normalizedPoint: BoardPoint? = nil,
        towards other: CGRect,
        rotationDegrees: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) -> CGPoint {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let normalizedPoint, normalizedPoint.x.isFinite, normalizedPoint.y.isFinite {
            var nx = max(0.0, min(1.0, normalizedPoint.x))
            var ny = max(0.0, min(1.0, normalizedPoint.y))
            if flipHorizontal { nx = 1.0 - nx }
            if flipVertical { ny = 1.0 - ny }
            let unrotated = CGPoint(
                x: rect.minX + rect.width * CGFloat(nx),
                y: rect.minY + rect.height * CGFloat(ny)
            )
            return rotatedPoint(unrotated, around: center, degrees: rotationDegrees)
        }
        let resolved: ConnectorAnchor
        if anchor == .auto {
            // Evaluate direction in local unrotated space when the node is rotated
            let otherLocal = rotatedPoint(CGPoint(x: other.midX, y: other.midY), around: center, degrees: -rotationDegrees)
            let dx = otherLocal.x - center.x
            let dy = otherLocal.y - center.y
            if abs(dx) >= abs(dy) {
                resolved = dx >= 0 ? .trailing : .leading
            } else {
                resolved = dy >= 0 ? .bottom : .top
            }
        } else {
            resolved = anchor
        }
        let unrotated: CGPoint = switch resolved {
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .leading: CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: CGPoint(x: rect.maxX, y: rect.midY)
        case .auto: center
        }
        return rotatedPoint(unrotated, around: center, degrees: rotationDegrees)
    }

    public static func resolvePathPoints(
        fromRect: CGRect,
        fromAnchor: ConnectorAnchor,
        fromNormalizedPoint: BoardPoint? = nil,
        fromRotationDegrees: Double = 0,
        fromFlipHorizontal: Bool = false,
        fromFlipVertical: Bool = false,
        toRect: CGRect,
        toAnchor: ConnectorAnchor,
        toNormalizedPoint: BoardPoint? = nil,
        toRotationDegrees: Double = 0,
        toFlipHorizontal: Bool = false,
        toFlipVertical: Bool = false,
        style: ConnectorStyle
    ) -> (start: CGPoint, end: CGPoint, control1: CGPoint, control2: CGPoint) {
        let start = anchorPoint(
            for: fromRect,
            anchor: fromAnchor,
            normalizedPoint: fromNormalizedPoint,
            towards: toRect,
            rotationDegrees: fromRotationDegrees,
            flipHorizontal: fromFlipHorizontal,
            flipVertical: fromFlipVertical
        )
        let end = anchorPoint(
            for: toRect,
            anchor: toAnchor,
            normalizedPoint: toNormalizedPoint,
            towards: fromRect,
            rotationDegrees: toRotationDegrees,
            flipHorizontal: toFlipHorizontal,
            flipVertical: toFlipVertical
        )
        let dist = max(48, hypot(end.x - start.x, end.y - start.y) * 0.36)

        func normalOffset(
            rect: CGRect,
            point: CGPoint,
            rotationDegrees: Double,
            isPinpoint: Bool,
            otherPoint: CGPoint
        ) -> CGSize {
            if isPinpoint {
                let dx = otherPoint.x - point.x
                let dy = otherPoint.y - point.y
                let length = max(1, hypot(dx, dy))
                let pull = min(dist * 0.65, length * 0.35)
                return CGSize(width: (dx / length) * pull, height: (dy / length) * pull)
            }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let localPt = rotatedPoint(point, around: center, degrees: -rotationDegrees)
            let localDir: CGSize
            if abs(localPt.y - rect.minY) < 1.5 { localDir = CGSize(width: 0, height: -dist) }
            else if abs(localPt.y - rect.maxY) < 1.5 { localDir = CGSize(width: 0, height: dist) }
            else if abs(localPt.x - rect.minX) < 1.5 { localDir = CGSize(width: -dist, height: 0) }
            else if abs(localPt.x - rect.maxX) < 1.5 { localDir = CGSize(width: dist, height: 0) }
            else { return CGSize(width: (end.x - start.x) * 0.25, height: 0) }

            let rotatedTip = rotatedPoint(CGPoint(x: localDir.width, y: localDir.height), around: .zero, degrees: rotationDegrees)
            return CGSize(width: rotatedTip.x, height: rotatedTip.y)
        }

        let n1 = normalOffset(rect: fromRect, point: start, rotationDegrees: fromRotationDegrees, isPinpoint: fromNormalizedPoint != nil, otherPoint: end)
        let n2 = normalOffset(rect: toRect, point: end, rotationDegrees: toRotationDegrees, isPinpoint: toNormalizedPoint != nil, otherPoint: start)
        let c1 = CGPoint(x: start.x + n1.width, y: start.y + n1.height)
        let c2 = CGPoint(x: end.x + n2.width, y: end.y + n2.height)
        return (start, end, c1, c2)
    }

    public static func midpoint(start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint, style: ConnectorStyle) -> CGPoint {
        switch style {
        case .straight:
            return CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        case .elbow:
            return CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        case .curved:
            // Cubic Bezier at t = 0.5
            let x = 0.125 * start.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * end.x
            let y = 0.125 * start.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * end.y
            return CGPoint(x: x, y: y)
        }
    }

    public static func distanceFromPoint(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let lenSq = vx * vx + vy * vy
        guard lenSq > 1e-6 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lenSq))
        let projX = a.x + t * vx
        let projY = a.y + t * vy
        return hypot(p.x - projX, p.y - projY)
    }

    public static func distanceToConnector(
        point: CGPoint,
        start: CGPoint,
        end: CGPoint,
        c1: CGPoint,
        c2: CGPoint,
        style: ConnectorStyle
    ) -> CGFloat {
        switch style {
        case .straight:
            return distanceFromPoint(point, toSegment: start, end)
        case .elbow:
            let midX = (start.x + end.x) * 0.5
            let p1 = CGPoint(x: midX, y: start.y)
            let p2 = CGPoint(x: midX, y: end.y)
            return min(
                distanceFromPoint(point, toSegment: start, p1),
                min(distanceFromPoint(point, toSegment: p1, p2), distanceFromPoint(point, toSegment: p2, end))
            )
        case .curved:
            let steps = 20
            var prev = start
            var best = CGFloat.greatestFiniteMagnitude
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let mt = 1 - t
                let x = mt * mt * mt * start.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * end.x
                let y = mt * mt * mt * start.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * end.y
                let cur = CGPoint(x: x, y: y)
                best = min(best, distanceFromPoint(point, toSegment: prev, cur))
                prev = cur
            }
            return best
        }
    }
}

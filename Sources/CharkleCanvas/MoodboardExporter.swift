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
/// for instant `⌘V` into Figma / Keynote / Freeform.
public enum MoodboardExporter {
    public static func renderImage(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions()
    ) -> NSImage? {
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

        // Compute tight bounding box across all nodes (and ink strokes if enabled)
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for node in document.nodes {
            guard let rect = resolvedFrames[node.id] else { continue }
            minX = min(minX, rect.minX)
            minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }
        if options.includeAnnotations {
            for stroke in document.inkStrokes {
                for pt in stroke.points {
                    minX = min(minX, pt.x - stroke.lineWidth)
                    minY = min(minY, pt.y - stroke.lineWidth)
                    maxX = max(maxX, pt.x + stroke.lineWidth)
                    maxY = max(maxY, pt.y + stroke.lineWidth)
                }
            }
        }

        if !minX.isFinite || !minY.isFinite || maxX <= minX || maxY <= minY {
            minX = 0
            minY = 0
            maxX = 960
            maxY = 640
        }

        let headerHeight: CGFloat = (options.includePaletteStrip && !document.extractedPalette.isEmpty) ? 72 : 44
        let pad = options.padding
        let contentW = CGFloat(maxX - minX)
        let contentH = CGFloat(maxY - minY)
        let canvasW = max(640, min(4800, contentW + pad * 2))
        let canvasH = max(420, min(4800, contentH + pad * 2 + headerHeight))

        let pixelW = Int((canvasW * options.scale).rounded())
        let pixelH = Int((canvasH * options.scale).rounded())

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
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = nsCtx
        let ctx = nsCtx.cgContext

        // Use flipped top-left coordinate system matching SwiftUI canvas coordinates
        ctx.translateBy(x: 0, y: canvasH)
        ctx.scaleBy(x: 1, y: -1)

        // Neutral gallery ground
        let bgColor = options.darkAppearance ? NSColor.charkleHex("#141517") : NSColor.charkleHex("#F6F6F5")
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

        let offsetX = pad - CGFloat(minX)
        let offsetY = pad + headerHeight - CGFloat(minY)

        // Draw nodes sorted by zIndex (group frames first)
        let orderedNodes = document.nodes.sorted { lhs, rhs in
            let lGroup = if case .groupFrame = lhs.kind { true } else { false }
            let rGroup = if case .groupFrame = rhs.kind { true } else { false }
            if lGroup != rGroup { return lGroup }
            return lhs.zIndex < rhs.zIndex
        }

        for node in orderedNodes {
            guard let baseRect = resolvedFrames[node.id] else { continue }
            let drawRect = CGRect(
                x: CGFloat(baseRect.x) + offsetX,
                y: CGFloat(baseRect.y) + offsetY,
                width: CGFloat(baseRect.width),
                height: CGFloat(baseRect.height)
            )
            drawNode(
                ctx: ctx,
                node: node,
                rect: drawRect,
                assetsByID: assetsByID,
                loader: loader,
                darkAppearance: options.darkAppearance
            )
        }

        // Connectors
        if options.includeAnnotations {
            for connector in document.connectors {
                guard let fromRect = resolvedFrames[connector.fromNodeID],
                      let toRect = resolvedFrames[connector.toNodeID] else { continue }
                let translatedFrom = CGRect(
                    x: CGFloat(fromRect.x) + offsetX,
                    y: CGFloat(fromRect.y) + offsetY,
                    width: CGFloat(fromRect.width),
                    height: CGFloat(fromRect.height)
                )
                let translatedTo = CGRect(
                    x: CGFloat(toRect.x) + offsetX,
                    y: CGFloat(toRect.y) + offsetY,
                    width: CGFloat(toRect.width),
                    height: CGFloat(toRect.height)
                )
                drawConnector(ctx: ctx, connector: connector, fromRect: translatedFrom, toRect: translatedTo)
            }

            // Freehand ink strokes
            for stroke in document.inkStrokes where stroke.points.count >= 2 {
                drawInkStroke(ctx: ctx, stroke: stroke, offsetX: offsetX, offsetY: offsetY)
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let finalImage = NSImage(size: NSSize(width: canvasW, height: canvasH))
        finalImage.addRepresentation(rep)
        return finalImage
    }

    @discardableResult
    public static func copyToPasteboard(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions()
    ) -> Bool {
        guard let image = renderImage(
            document: document,
            assetsByID: assetsByID,
            loader: loader,
            containerWidth: containerWidth,
            options: options
        ),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        pb.setData(tiff, forType: .tiff)
        return true
    }

    public static func exportToFile(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        url: URL,
        format: MoodboardExportFormat,
        containerWidth: Double = 1120,
        options: MoodboardExportOptions = MoodboardExportOptions()
    ) throws {
        guard let image = renderImage(
            document: document,
            assetsByID: assetsByID,
            loader: loader,
            containerWidth: containerWidth,
            options: options
        ),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
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
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: inkPrimary
        ]
        NSString(string: document.title).draw(at: NSPoint(x: padding, y: padding * 0.65), withAttributes: titleAttr)

        if !document.subtitle.isEmpty {
            let subAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: inkSecondary
            ]
            NSString(string: document.subtitle).draw(at: NSPoint(x: padding, y: padding * 0.65 + 26), withAttributes: subAttr)
        }

        if includePalette, !document.extractedPalette.isEmpty {
            let swatches = Array(document.extractedPalette.prefix(7))
            let swatchW: CGFloat = 28
            let swatchH: CGFloat = 20
            let gap: CGFloat = 6
            let totalW = CGFloat(swatches.count) * swatchW + CGFloat(max(0, swatches.count - 1)) * gap
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
    }

    private static func drawNode(
        ctx: CGContext,
        node: BoardNode,
        rect: CGRect,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        darkAppearance: Bool
    ) {
        ctx.saveGState()
        if abs(node.rotationDegrees) > 0.1 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: CGFloat(node.rotationDegrees * .pi / 180.0))
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }

        switch node.kind {
        case .assetRef(let assetID, _, _, _):
            let clipPath = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()

            if let nsImg = loader.cachedImage(for: assetID, tier: .preview1400)
                ?? loader.cachedImage(for: assetID, tier: .grid520),
               let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
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
                let hex = asset?.dominantColors.first?.hex ?? (darkAppearance ? "#2B2F36" : "#DFDDD7")
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

            var textY = rect.minY + 14
            if let title, !title.isEmpty {
                let titleAttr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: CGFloat(max(13, fontSize)), weight: .semibold),
                    .foregroundColor: fg
                ]
                NSString(string: title).draw(in: CGRect(x: rect.minX + 14, y: textY, width: rect.width - 28, height: 24), withAttributes: titleAttr)
                textY += 24
            }
            let bodyAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: CGFloat(max(11, fontSize - 1)), weight: .regular),
                .foregroundColor: fg.withAlphaComponent(0.86)
            ]
            NSString(string: text).draw(in: CGRect(x: rect.minX + 14, y: textY, width: rect.width - 28, height: max(20, rect.maxY - textY - 12)), withAttributes: bodyAttr)

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

            let attr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: darkAppearance ? NSColor.white.withAlphaComponent(0.88) : NSColor.black.withAlphaComponent(0.78)
            ]
            NSString(string: title).draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 10), withAttributes: attr)

        case .paletteStrip(let colors, _):
            let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(path)
            ctx.clip()
            let list = colors.isEmpty ? [LabColor.fromHex("#808080")] : colors
            let segW = rect.width / CGFloat(list.count)
            for (idx, color) in list.enumerated() {
                let r = CGRect(x: rect.minX + CGFloat(idx) * segW, y: rect.minY, width: segW + 0.5, height: rect.height)
                ctx.setFillColor(NSColor.charkleHex(color.hex).cgColor)
                ctx.fill(r)
                let attr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: Color.charkleIsLightHex(color.hex) ? NSColor.black.withAlphaComponent(0.78) : NSColor.white.withAlphaComponent(0.88)
                ]
                NSString(string: color.hex.uppercased()).draw(at: NSPoint(x: r.minX + 8, y: r.maxY - 20), withAttributes: attr)
            }
        }

        ctx.restoreGState()
    }

    private static func drawConnector(
        ctx: CGContext,
        connector: BoardConnector,
        fromRect: CGRect,
        toRect: CGRect
    ) {
        let (start, end, c1, c2) = ConnectorGeometry.resolvePathPoints(
            fromRect: fromRect,
            fromAnchor: connector.fromAnchor,
            toRect: toRect,
            toAnchor: connector.toAnchor,
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
        ctx.restoreGState()
    }

    private static func drawInkStroke(ctx: CGContext, stroke: InkStroke, offsetX: CGFloat, offsetY: CGFloat) {
        let pts = stroke.points.map { CGPoint(x: CGFloat($0.x) + offsetX, y: CGFloat($0.y) + offsetY) }
        guard pts.count >= 2 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.charkleHex(stroke.colorHex).withAlphaComponent(CGFloat(stroke.opacity)).cgColor)
        ctx.setLineWidth(CGFloat(stroke.lineWidth))
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
        case .paper: (NSColor.charkleHex("#FFFFFF"), NSColor.charkleHex("#1E2024"))
        case .ink: (NSColor.charkleHex("#1E2025"), NSColor.charkleHex("#F2F3F5"))
        case .warm: (NSColor.charkleHex("#F6EFE2"), NSColor.charkleHex("#3B3124"))
        case .sage: (NSColor.charkleHex("#E7EFE9"), NSColor.charkleHex("#233329"))
        case .slate: (NSColor.charkleHex("#E8EDF2"), NSColor.charkleHex("#212D38"))
        }
    }

    private static func groupTintNSColor(_ tint: GroupTint) -> NSColor {
        switch tint {
        case .neutral: NSColor.charkleHex("#7E848C")
        case .sand: NSColor.charkleHex("#B6976E")
        case .sage: NSColor.charkleHex("#6D8F78")
        case .slate: NSColor.charkleHex("#667C94")
        case .terracotta: NSColor.charkleHex("#BA6B55")
        case .ocean: NSColor.charkleHex("#4E7D96")
        }
    }
}

/// Shared connector path routing geometry used by both live SwiftUI Canvas and High-DPI Exporter.
public nonisolated enum ConnectorGeometry {
    public static func anchorPoint(for rect: CGRect, anchor: ConnectorAnchor, towards other: CGRect) -> CGPoint {
        let resolved: ConnectorAnchor
        if anchor == .auto {
            let dx = other.midX - rect.midX
            let dy = other.midY - rect.midY
            if abs(dx) >= abs(dy) {
                resolved = dx >= 0 ? .trailing : .leading
            } else {
                resolved = dy >= 0 ? .bottom : .top
            }
        } else {
            resolved = anchor
        }
        return switch resolved {
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .leading: CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: CGPoint(x: rect.maxX, y: rect.midY)
        case .auto: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    public static func resolvePathPoints(
        fromRect: CGRect,
        fromAnchor: ConnectorAnchor,
        toRect: CGRect,
        toAnchor: ConnectorAnchor,
        style: ConnectorStyle
    ) -> (start: CGPoint, end: CGPoint, control1: CGPoint, control2: CGPoint) {
        let start = anchorPoint(for: fromRect, anchor: fromAnchor, towards: toRect)
        let end = anchorPoint(for: toRect, anchor: toAnchor, towards: fromRect)
        let dist = max(48, hypot(end.x - start.x, end.y - start.y) * 0.36)

        func normalOffset(rect: CGRect, point: CGPoint) -> CGSize {
            if abs(point.y - rect.minY) < 1.5 { return CGSize(width: 0, height: -dist) }
            if abs(point.y - rect.maxY) < 1.5 { return CGSize(width: 0, height: dist) }
            if abs(point.x - rect.minX) < 1.5 { return CGSize(width: -dist, height: 0) }
            if abs(point.x - rect.maxX) < 1.5 { return CGSize(width: dist, height: 0) }
            return CGSize(width: (end.x - start.x) * 0.25, height: 0)
        }

        let n1 = normalOffset(rect: fromRect, point: start)
        let n2 = normalOffset(rect: toRect, point: end)
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
}

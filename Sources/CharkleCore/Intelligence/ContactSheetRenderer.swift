import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public nonisolated struct ContactSheetBatch: Sendable {
    public let jpegData: Data
    public let slotToAssetID: [Int: UUID]
    public let orderedSlots: [(slot: Int, assetID: UUID)]
    public let width: Int
    public let height: Int

    public init(
        jpegData: Data,
        slotToAssetID: [Int: UUID],
        orderedSlots: [(slot: Int, assetID: UUID)],
        width: Int,
        height: Int
    ) {
        self.jpegData = jpegData
        self.slotToAssetID = slotToAssetID
        self.orderedSlots = orderedSlots
        self.width = width
        self.height = height
    }
}

/// Pure CoreGraphics / CoreText numbered Visual Contact Sheet renderer.
///
/// Stitches up to 16 candidate thumbnails into a crisp studio-dark JPEG grid with high-contrast
/// `#01`..`#16` slot badges so multimodal LLMs (built-in Agent Harness or external MCP Agents)
/// can inspect 16–32 assets in 1–2 images with deterministic integer grounding (zero UUID hallucinations).
public nonisolated enum ContactSheetRenderer {
    public struct Entry: Sendable {
        public let slot: Int
        public let asset: AssetRecord
        public let thumbnailURL: URL?

        public init(slot: Int, asset: AssetRecord, thumbnailURL: URL?) {
            self.slot = slot
            self.asset = asset
            self.thumbnailURL = thumbnailURL
        }
    }

    public static func render(
        entries: [Entry],
        maxCanvasWidth: Int = 1280,
        jpegQuality: Double = 0.78
    ) -> ContactSheetBatch? {
        guard !entries.isEmpty else { return nil }
        let count = entries.count
        let columns: Int = switch count {
        case 1...4: min(2, count)
        case 5...9: 3
        default: 4
        }
        let rows = Int(ceil(Double(count) / Double(columns)))
        let margin: CGFloat = 18
        let gap: CGFloat = 14
        let canvasWidth = CGFloat(max(640, maxCanvasWidth))
        let cellWidth = floor((canvasWidth - margin * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let cellHeight = floor(cellWidth * 0.82)
        let canvasHeight = margin * 2 + CGFloat(rows) * cellHeight + CGFloat(max(0, rows - 1)) * gap

        let pixelWidth = Int(canvasWidth)
        let pixelHeight = Int(canvasHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Flip coordinates so y=0 is top-left for clean grid math
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0.094, green: 0.102, blue: 0.122, alpha: 1.0)) // #181A1F studio dark
        ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

        var slotMap: [Int: UUID] = [:]
        var ordered: [(Int, UUID)] = []

        for (idx, entry) in entries.enumerated() {
            let col = idx % columns
            let row = idx / columns
            let x = margin + CGFloat(col) * (cellWidth + gap)
            // CoreGraphics origin is bottom-left
            let yTop = margin + CGFloat(row) * (cellHeight + gap)
            let yBottom = canvasHeight - yTop - cellHeight
            let tileRect = CGRect(x: x, y: yBottom, width: cellWidth, height: cellHeight)

            // Subtle neutral tile backing
            let tilePath = CGPath(roundedRect: tileRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.addPath(tilePath)
            ctx.clip()

            ctx.setFillColor(CGColor(red: 0.145, green: 0.155, blue: 0.180, alpha: 1.0))
            ctx.fill(tileRect)

            if let thumbURL = entry.thumbnailURL, let image = loadCGImage(at: thumbURL) {
                let insetRect = tileRect.insetBy(dx: 4, dy: 4)
                let drawRect = aspectFitRect(imageWidth: CGFloat(image.width), imageHeight: CGFloat(image.height), inside: insetRect)
                ctx.draw(image, in: drawRect)
            } else if let firstColor = entry.asset.dominantColors.first,
                      let rgb = hexToRGB(firstColor.hex) {
                ctx.setFillColor(CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0.85))
                ctx.fill(tileRect.insetBy(dx: 12, dy: 12))
            }
            ctx.restoreGState()

            // Crisp tile hairline border
            ctx.saveGState()
            ctx.addPath(tilePath)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
            ctx.setLineWidth(1.0)
            ctx.strokePath()
            ctx.restoreGState()

            // High-contrast top-left numbered badge `#01`, `#02`, ...
            let labelText = String(format: "#%02d", entry.slot)
            drawPillBadge(
                text: labelText,
                in: ctx,
                topLeftX: tileRect.minX + 8,
                topLeftYFromBottom: tileRect.maxY - 8,
                fontSize: columns >= 4 ? 17 : 20,
                background: CGColor(red: 0, green: 0, blue: 0, alpha: 0.88),
                border: CGColor(red: 1, green: 1, blue: 1, alpha: 0.85),
                textColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            )

            // Optional non-image media indicator badge top-right
            if let mediaBadge = mediaBadgeLabel(for: entry.asset.mediaKind) {
                drawPillBadge(
                    text: mediaBadge,
                    in: ctx,
                    topRightX: tileRect.maxX - 8,
                    topLeftYFromBottom: tileRect.maxY - 8,
                    fontSize: 12,
                    background: CGColor(red: 0.12, green: 0.36, blue: 0.78, alpha: 0.90),
                    border: CGColor(red: 1, green: 1, blue: 1, alpha: 0.45),
                    textColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                )
            }

            slotMap[entry.slot] = entry.asset.id
            ordered.append((entry.slot, entry.asset.id))
        }

        guard let cgImage = ctx.makeImage(),
              let jpegData = encodeJPEG(cgImage, quality: jpegQuality) else {
            return nil
        }

        return ContactSheetBatch(
            jpegData: jpegData,
            slotToAssetID: slotMap,
            orderedSlots: ordered,
            width: pixelWidth,
            height: pixelHeight
        )
    }

    private static func mediaBadgeLabel(for kind: MediaKind) -> String? {
        switch kind {
        case .video: "VID"
        case .animatedImage: "GIF"
        case .document: "PDF"
        case .webBookmark: "WEB"
        case .designFile: "DES"
        case .audio: "AUD"
        case .image: nil
        }
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func aspectFitRect(imageWidth: CGFloat, imageHeight: CGFloat, inside bounds: CGRect) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return bounds }
        let scale = min(bounds.width / imageWidth, bounds.height / imageHeight)
        let w = imageWidth * scale
        let h = imageHeight * scale
        return CGRect(
            x: bounds.midX - w * 0.5,
            y: bounds.midY - h * 0.5,
            width: w,
            height: h
        )
    }

    private static func drawPillBadge(
        text: String,
        in ctx: CGContext,
        topLeftX: CGFloat? = nil,
        topRightX: CGFloat? = nil,
        topLeftYFromBottom: CGFloat,
        fontSize: CGFloat,
        background: CGColor,
        border: CGColor,
        textColor: CGColor
    ) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: textColor
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let textHeight = ascent + descent

        let padX: CGFloat = 8
        let padY: CGFloat = 4
        let pillW = ceil(textWidth + padX * 2)
        let pillH = ceil(textHeight + padY * 2)
        let originX: CGFloat = if let left = topLeftX {
            left
        } else if let right = topRightX {
            right - pillW
        } else {
            0
        }
        let pillRect = CGRect(x: originX, y: topLeftYFromBottom - pillH, width: pillW, height: pillH)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillH * 0.45, cornerHeight: pillH * 0.45, transform: nil)

        ctx.saveGState()
        ctx.addPath(pillPath)
        ctx.setFillColor(background)
        ctx.fillPath()
        ctx.addPath(pillPath)
        ctx.setStrokeColor(border)
        ctx.setLineWidth(1.25)
        ctx.strokePath()

        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: pillRect.minX + padX, y: pillRect.minY + padY + descent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func hexToRGB(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return (
            CGFloat((value >> 16) & 0xFF) / 255.0,
            CGFloat((value >> 8) & 0xFF) / 255.0,
            CGFloat(value & 0xFF) / 255.0
        )
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }
}

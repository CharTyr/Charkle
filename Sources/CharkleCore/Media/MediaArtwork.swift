import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum MediaArtwork {
    static func context(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func resize(_ source: CGImage, maxSide: Int) -> CGImage? {
        let scale = min(1, Double(maxSide) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        guard let ctx = context(width: width, height: height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(bounds)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: bounds)
        return ctx.makeImage()
    }

    static func encode(_ image: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.84] : [:]
        CGImageDestinationAddImage(writer, image, options as CFDictionary)
        return CGImageDestinationFinalize(writer) ? data as Data : nil
    }

    static func color(_ hex: UInt32) -> CGColor {
        CGColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: 1)
    }

    static func card(title: String, label: String, text: String, waveform: [Float] = []) -> CGImage? {
        guard let ctx = context(width: 800, height: 570) else { return nil }
        ctx.setFillColor(color(0xF0ECE3))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 570))
        ctx.setFillColor(color(0xB9543C))
        ctx.fill(CGRect(x: 46, y: 506, width: 30, height: 5))
        draw(label, in: ctx, at: CGPoint(x: 92, y: 499), size: 19, ink: 0x675C52, width: 650)
        draw(title, in: ctx, at: CGPoint(x: 46, y: 416), size: 39, ink: 0x25231F, width: 710)
        ctx.setFillColor(color(0xD4C9B8))
        ctx.fill(CGRect(x: 46, y: 372, width: 708, height: 2))
        if waveform.isEmpty {
            let lines = text.split(whereSeparator: \.isNewline).prefix(9)
            for (index, line) in lines.enumerated() {
                draw(String(line.prefix(150)), in: ctx, at: CGPoint(x: 46, y: 332 - index * 32),
                     size: 20, ink: 0x554E45, width: 708)
            }
        } else {
            ctx.setFillColor(color(0x795144))
            let step = 708 / Double(waveform.count)
            for (index, peak) in waveform.enumerated() {
                let height = max(3, Double(peak) * 200)
                ctx.fill(CGRect(x: 46 + Double(index) * step, y: 205 - height / 2, width: step * 0.59, height: height))
            }
        }
        return ctx.makeImage()
    }

    static func swatch(_ swatch: LabColor) -> CGImage? {
        guard let ctx = context(width: 720, height: 620) else { return nil }
        ctx.setFillColor(color(UInt32(swatch.hex.dropFirst(), radix: 16) ?? 0x808080))
        ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 620))
        ctx.setFillColor(color(0xF7F3E9))
        ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 110))
        draw(swatch.hex, in: ctx, at: CGPoint(x: 42, y: 42), size: 31, ink: 0x25231F, width: 600)
        return ctx.makeImage()
    }

    static func draw(_ text: String, in ctx: CGContext, at position: CGPoint, size: Double, ink: UInt32, width: Double) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(ink)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let visible = CTLineCreateTruncatedLine(line, width, .end, ellipsis) ?? line
        ctx.textPosition = position
        CTLineDraw(visible, ctx)
    }
}

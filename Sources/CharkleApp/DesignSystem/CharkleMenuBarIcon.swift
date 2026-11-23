import AppKit
import CoreGraphics

/// Native CoreGraphics macOS Menu Bar template icon derived directly from the official Charkle emblem
/// (sculpted mantle hood, punched-out vertical pill eyes, flowing skirt, and lower tail swirl).
///
/// Rendered via `NSImage(size:flipped:drawingHandler:)` with `isTemplate = true` and true `.clear`
/// alpha punch-outs so macOS automatically tints it to exact Light/Dark menu bar ink at 1x/2x/3x Retina.
public enum CharkleMenuBarIcon {
    private static let cachedTemplate: NSImage = buildTemplateImage(size: NSSize(width: 18, height: 18))

    public static func templateImage(pointSize: CGFloat = 18) -> NSImage {
        if abs(pointSize - 18) < 0.01 {
            return cachedTemplate
        }
        return buildTemplateImage(size: NSSize(width: pointSize, height: pointSize))
    }

    private static func buildTemplateImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawEmblem(in: ctx, bounds: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawEmblem(in ctx: CGContext, bounds: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Render inside an isolated transparency layer so `.clear` blend mode punches true alpha
        // holes without disturbing anything outside the icon bounds.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }

        // Map raw Charkle emblem coordinates (x: 290..955, y: 260..971; center 622.5, 616) into 18x18 HIG box.
        let side = min(bounds.width, bounds.height)
        let scale = (side / 18.0) * 0.0226
        ctx.translateBy(x: bounds.midX, y: bounds.midY + (side / 18.0) * 0.06)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -622.5, y: -616.0)

        let ink = CGColor(gray: 0.0, alpha: 1.0)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        let tail = makeTailPath()
        let skirt = makeSkirtPath()
        let mantle = makeMantlePath()

        // 1. Lower tail swirl (nudged +8 raw units downward so the right curl stays balanced at 18pt)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: 8)
        ctx.setFillColor(ink)
        ctx.addPath(tail)
        ctx.fillPath()
        ctx.restoreGState()

        // 2. Negative-space fold channel between skirt and tail
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(skirt)
        ctx.fillPath()
        ctx.setLineWidth(44)
        ctx.addPath(skirt)
        ctx.strokePath()
        ctx.restoreGState()

        // 3. Flowing skirt
        ctx.setFillColor(ink)
        ctx.addPath(skirt)
        ctx.fillPath()

        // 4. Negative-space fold channel between hood/mantle and skirt
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.addPath(mantle)
        ctx.fillPath()
        ctx.setLineWidth(54)
        ctx.addPath(mantle)
        ctx.strokePath()
        ctx.restoreGState()

        // 5. Iconic sculpted hood / mantle
        ctx.setFillColor(ink)
        ctx.addPath(mantle)
        ctx.fillPath()

        // 6. Punched-out vertical pill eyes (optically strengthened for 18pt menu bar clarity)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        let leftEye = CGPath(roundedRect: CGRect(x: 494, y: 528, width: 62, height: 136), cornerWidth: 31, cornerHeight: 31, transform: nil)
        let rightEye = CGPath(roundedRect: CGRect(x: 695, y: 528, width: 62, height: 136), cornerWidth: 31, cornerHeight: 31, transform: nil)
        ctx.addPath(leftEye)
        ctx.addPath(rightEye)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func makeTailPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 457.76, y: 872.11))
        p.addCurve(to: CGPoint(x: 709.35, y: 793.36), control1: CGPoint(x: 517.82, y: 822.39), control2: CGPoint(x: 642.31, y: 780.40))
        p.addCurve(to: CGPoint(x: 848.89, y: 895.90), control1: CGPoint(x: 770.34, y: 805.24), control2: CGPoint(x: 844.40, y: 868.52))
        p.addCurve(to: CGPoint(x: 801.09, y: 921.47), control1: CGPoint(x: 850.83, y: 909.07), control2: CGPoint(x: 824.57, y: 921.67))
        p.addCurve(to: CGPoint(x: 697.04, y: 902.22), control1: CGPoint(x: 762.13, y: 921.14), control2: CGPoint(x: 735.13, y: 901.89))
        p.addCurve(to: CGPoint(x: 484.02, y: 970.92), control1: CGPoint(x: 621.10, y: 902.93), control2: CGPoint(x: 570.83, y: 971.34))
        p.addCurve(to: CGPoint(x: 424.01, y: 930.68), control1: CGPoint(x: 445.69, y: 970.70), control2: CGPoint(x: 422.65, y: 955.02))
        p.addCurve(to: CGPoint(x: 457.76, y: 872.11), control1: CGPoint(x: 425.09, y: 911.95), control2: CGPoint(x: 444.61, y: 883.35))
        p.closeSubpath()
        return p
    }

    private static func makeSkirtPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 450.93, y: 687.91))
        p.addCurve(to: CGPoint(x: 796.68, y: 692.29), control1: CGPoint(x: 524.00, y: 663.00), control2: CGPoint(x: 733.00, y: 658.00))
        p.addCurve(to: CGPoint(x: 891.26, y: 817.12), control1: CGPoint(x: 805.83, y: 739.71), control2: CGPoint(x: 847.55, y: 794.08))
        p.addCurve(to: CGPoint(x: 933.84, y: 849.61), control1: CGPoint(x: 907.07, y: 825.57), control2: CGPoint(x: 932.22, y: 832.37))
        p.addCurve(to: CGPoint(x: 880.47, y: 892.10), control1: CGPoint(x: 935.53, y: 867.69), control2: CGPoint(x: 906.29, y: 884.68))
        p.addCurve(to: CGPoint(x: 741.86, y: 867.96), control1: CGPoint(x: 830.02, y: 906.50), control2: CGPoint(x: 783.92, y: 890.96))
        p.addCurve(to: CGPoint(x: 610.45, y: 817.53), control1: CGPoint(x: 694.00, y: 841.58), control2: CGPoint(x: 654.33, y: 817.40))
        p.addCurve(to: CGPoint(x: 438.38, y: 876.15), control1: CGPoint(x: 547.50, y: 817.49), control2: CGPoint(x: 500.66, y: 867.45))
        p.addCurve(to: CGPoint(x: 327.39, y: 849.16), control1: CGPoint(x: 396.96, y: 882.01), control2: CGPoint(x: 356.18, y: 870.49))
        p.addCurve(to: CGPoint(x: 320.42, y: 816.52), control1: CGPoint(x: 312.18, y: 837.88), control2: CGPoint(x: 312.64, y: 824.41))
        p.addCurve(to: CGPoint(x: 360.55, y: 798.08), control1: CGPoint(x: 328.95, y: 807.79), control2: CGPoint(x: 345.98, y: 804.38))
        p.addCurve(to: CGPoint(x: 450.93, y: 687.91), control1: CGPoint(x: 406.50, y: 778.36), control2: CGPoint(x: 437.32, y: 731.99))
        p.closeSubpath()
        return p
    }

    private static func makeMantlePath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 625.96, y: 260.40))
        p.addCurve(to: CGPoint(x: 684.73, y: 281.68), control1: CGPoint(x: 646.72, y: 260.14), control2: CGPoint(x: 666.00, y: 267.92))
        p.addCurve(to: CGPoint(x: 917.93, y: 542.53), control1: CGPoint(x: 761.15, y: 338.59), control2: CGPoint(x: 862.05, y: 452.92))
        p.addCurve(to: CGPoint(x: 954.21, y: 637.87), control1: CGPoint(x: 941.14, y: 579.84), control2: CGPoint(x: 954.40, y: 613.11))
        p.addCurve(to: CGPoint(x: 923.80, y: 693.51), control1: CGPoint(x: 954.01, y: 668.96), control2: CGPoint(x: 940.97, y: 682.62))
        p.addCurve(to: CGPoint(x: 804.42, y: 719.43), control1: CGPoint(x: 894.90, y: 712.05), control2: CGPoint(x: 850.62, y: 712.34))
        p.addCurve(to: CGPoint(x: 438.61, y: 717.62), control1: CGPoint(x: 742.00, y: 825.00), control2: CGPoint(x: 501.00, y: 821.00))
        p.addCurve(to: CGPoint(x: 321.93, y: 690.07), control1: CGPoint(x: 394.82, y: 712.89), control2: CGPoint(x: 346.90, y: 705.35))
        p.addCurve(to: CGPoint(x: 290.84, y: 636.86), control1: CGPoint(x: 305.20, y: 679.91), control2: CGPoint(x: 291.41, y: 667.45))
        p.addCurve(to: CGPoint(x: 327.52, y: 543.70), control1: CGPoint(x: 291.33, y: 609.67), control2: CGPoint(x: 306.11, y: 577.33))
        p.addCurve(to: CGPoint(x: 567.85, y: 281.29), control1: CGPoint(x: 383.94, y: 455.45), control2: CGPoint(x: 494.03, y: 332.60))
        p.addCurve(to: CGPoint(x: 625.96, y: 260.40), control1: CGPoint(x: 588.91, y: 266.76), control2: CGPoint(x: 606.76, y: 260.76))
        p.closeSubpath()
        return p
    }
}

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates a curated set of high-craft design reference images on-device
/// so first-time users can immediately experience the waterfall grid, color search,
/// OCR, Quick Look, visual similarity, and built-in media tools with zero external dependencies.
nonisolated enum SampleLibrarySeeder: Sendable {

    struct SampleSpec: Sendable {
        let title: String
        let fileName: String
        let folderName: String
        let tags: [String]
        let rating: Int
        let notes: String
        let width: Int
        let height: Int
        let style: Style

        enum Style: Sendable {
            case darkDashboard
            case swissSerifPoster
            case warmEditorial
            case cobaltGradientHero
            case bauhausGeometric
            case emeraldMobileFintech
            case monochromeTerminal
            case ceramicGlazes
            case limestoneArchitecture
            case botanicalStudy
        }
    }

    static let sampleSpecs: [SampleSpec] = [
        SampleSpec(
            title: "Dark Admin Dashboard",
            fileName: "Dark Admin Dashboard.png",
            folderName: "UI Inspiration",
            tags: ["dashboard", "dark-ui", "analytics", "暗黑仪表盘"],
            rating: 5,
            notes: "Clean dark obsidian surfaces with electric indigo data series and hairline dividers.",
            width: 1200,
            height: 820,
            style: .darkDashboard
        ),
        SampleSpec(
            title: "Serif Typography Poster — Zurich 2026",
            fileName: "Serif Typography Poster.png",
            folderName: "Typography",
            tags: ["serif", "poster", "typography", "瑞士排版", "海报"],
            rating: 5,
            notes: "High-contrast serif display type with asymmetric Swiss grid margins.",
            width: 840,
            height: 1180,
            style: .swissSerifPoster
        ),
        SampleSpec(
            title: "Warm Financial Editorial Spread",
            fileName: "Warm Editorial Spread.png",
            folderName: "Editorial",
            tags: ["editorial", "warm", "magazine", "暖色调", "排版"],
            rating: 4,
            notes: "Paper cream background with warm amber highlights and structured metrics.",
            width: 1160,
            height: 860,
            style: .warmEditorial
        ),
        SampleSpec(
            title: "Automation Hero Blue",
            fileName: "Automation Hero Blue.png",
            folderName: "UI Inspiration",
            tags: ["hero", "saas", "blue", "landing-page", "蓝色"],
            rating: 5,
            notes: "Deep cobalt radial lighting with crisp white typography and pill CTA.",
            width: 1280,
            height: 760,
            style: .cobaltGradientHero
        ),
        SampleSpec(
            title: "Bauhaus Form & Rhythm Study",
            fileName: "Bauhaus Form Study.png",
            folderName: "Typography",
            tags: ["bauhaus", "geometric", "poster", "包豪斯", "几何"],
            rating: 4,
            notes: "Primary vermilion, ochre, and cobalt shapes balanced on matte charcoal.",
            width: 960,
            height: 960,
            style: .bauhausGeometric
        ),
        SampleSpec(
            title: "Emerald Mobile Fintech Wallet",
            fileName: "Emerald Fintech Mobile.png",
            folderName: "UI Inspiration",
            tags: ["mobile", "fintech", "emerald", "ios", "金融App"],
            rating: 4,
            notes: "Portrait card hierarchy with translucent emerald card and tabular numbers.",
            width: 760,
            height: 1160,
            style: .emeraldMobileFintech
        ),
        SampleSpec(
            title: "Monospace Workflow Monitor",
            fileName: "Monospace Workflow Monitor.png",
            folderName: "UI Inspiration",
            tags: ["developer", "terminal", "dark-ui", "monospace", "工具"],
            rating: 5,
            notes: "High-density technical telemetry panel with crisp status pills.",
            width: 1200,
            height: 800,
            style: .monochromeTerminal
        ),
        SampleSpec(
            title: "Terracotta Studio — Ceramic Glaze Studies",
            fileName: "Terracotta Studio Identity.png",
            folderName: "",
            tags: ["ceramic", "terracotta", "minimal", "品牌", "陶土色"],
            rating: 4,
            notes: "Earthy terracotta primary swatch paired with chalk off-white stationery.",
            width: 900,
            height: 1100,
            style: .ceramicGlazes
        ),
        SampleSpec(title: "Limestone Courtyard — Study in Shadow", fileName: "Limestone Courtyard.png",
                   folderName: "Architecture", tags: ["architecture", "limestone", "建筑", "午后"],
                   rating: 5, notes: "A low sun cuts across three stone thresholds.",
                   width: 1200, height: 900, style: .limestoneArchitecture),
        SampleSpec(title: "Herbarium — Silver Eucalyptus", fileName: "Silver Eucalyptus.png",
                   folderName: "", tags: ["botanical", "sage", "植物", "叶片"],
                   rating: 4, notes: "An archival plate studying stems and paired leaves.",
                   width: 900, height: 1160, style: .botanicalStudy)
    ]

    static func renderPNG(for spec: SampleSpec) -> Data? {
        let w = spec.width
        let h = spec.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // Flip to top-left origin for intuitive layout math, then draw text unflipped via helper
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        switch spec.style {
        case .darkDashboard:
            drawDarkDashboard(ctx: ctx, rect: rect)
        case .swissSerifPoster:
            drawSwissPoster(ctx: ctx, rect: rect)
        case .warmEditorial:
            drawWarmEditorial(ctx: ctx, rect: rect)
        case .cobaltGradientHero:
            drawCobaltHero(ctx: ctx, rect: rect)
        case .bauhausGeometric:
            drawBauhaus(ctx: ctx, rect: rect)
        case .emeraldMobileFintech:
            drawEmeraldMobile(ctx: ctx, rect: rect)
        case .monochromeTerminal:
            drawMonochromeTerminal(ctx: ctx, rect: rect)
        case .ceramicGlazes:
            drawCeramicGlazes(ctx, rect)
        case .limestoneArchitecture:
            drawArchitecture(ctx, rect)
        case .botanicalStudy:
            drawBotanical(ctx, rect)
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Artworks

    private static func drawDarkDashboard(ctx: CGContext, rect: CGRect) {
        fill(ctx, rect, hex: 0x0E1015)
        // Left sidebar panel
        fillRounded(ctx, CGRect(x: 36, y: 36, width: 220, height: rect.height - 72), radius: 22, hex: 0x161922)
        // Main header
        drawText(ctx, "REVENUE ANALYTICS", at: CGPoint(x: 296, y: rect.height - 96), size: 15, weight: .semibold, hex: 0x8B93A7)
        drawText(ctx, "$482,910", at: CGPoint(x: 296, y: rect.height - 154), size: 50, weight: .bold, hex: 0xF5F7FA)
        // KPI cards
        let cardColors: [UInt32] = [0x1A1E2A, 0x1A1E2A, 0x1A1E2A]
        let metrics = [("ACTIVE NODES", "18 DIRECT"), ("LATENCY", "42 MS"), ("SYNC RATE", "99.98%")]
        for i in 0..<3 {
            let x = 296.0 + Double(i) * 288.0
            fillRounded(ctx, CGRect(x: x, y: rect.height - 300, width: 264, height: 112), radius: 18, hex: cardColors[i])
            drawText(ctx, metrics[i].0, at: CGPoint(x: x + 22, y: rect.height - 224), size: 13, weight: .semibold, hex: 0x7A839B)
            drawText(ctx, metrics[i].1, at: CGPoint(x: x + 22, y: rect.height - 270), size: 28, weight: .bold, hex: 0xE6ECF8)
        }
        // Bar chart card
        fillRounded(ctx, CGRect(x: 296, y: 52, width: 840, height: 420), radius: 22, hex: 0x161922)
        let heights: [CGFloat] = [120, 175, 140, 230, 290, 255, 320, 275, 340, 305, 355, 330]
        for (i, bh) in heights.enumerated() {
            let bx = 342.0 + CGFloat(i) * 62.0
            let color: UInt32 = i >= 8 ? 0x5E6AD2 : 0x2B3248
            fillRounded(ctx, CGRect(x: bx, y: 92, width: 38, height: bh), radius: 10, hex: color)
        }
        // Sidebar dots
        for i in 0..<6 {
            fillRounded(ctx, CGRect(x: 62, y: rect.height - 130 - CGFloat(i) * 58, width: 168, height: 34), radius: 10, hex: i == 0 ? 0x5E6AD2 : 0x222736)
        }
    }

    private static func drawSwissPoster(ctx: CGContext, rect: CGRect) {
        fill(ctx, rect, hex: 0xF4EFE6)
        // Bold crimson geometric anchor
        fillCircle(ctx, center: CGPoint(x: rect.width * 0.68, y: rect.height * 0.34), radius: 220, hex: 0xD93829)
        fill(ctx, CGRect(x: 64, y: rect.height - 120, width: rect.width - 128, height: 3), hex: 0x191816)
        drawText(ctx, "KUNSTHALLE ZURICH · ARCHIVE", at: CGPoint(x: 64, y: rect.height - 96), size: 18, weight: .semibold, hex: 0x191816)
        drawText(ctx, "SERIF", at: CGPoint(x: 58, y: rect.height - 320), size: 172, weight: .bold, hex: 0x191816, serif: true)
        drawText(ctx, "FORM", at: CGPoint(x: 58, y: rect.height - 486), size: 172, weight: .bold, hex: 0x191816, serif: true)
        drawText(ctx, "TYPOGRAPHY POSTER", at: CGPoint(x: 64, y: 120), size: 28, weight: .medium, hex: 0x191816)
        drawText(ctx, "NOV 2026 — EDITION 04", at: CGPoint(x: 64, y: 78), size: 18, weight: .regular, hex: 0x5C574F)
    }

    private static func drawWarmEditorial(ctx: CGContext, rect: CGRect) {
        fill(ctx, rect, hex: 0xF7F1E5)
        fillRounded(ctx, CGRect(x: 56, y: 56, width: 520, height: rect.height - 112), radius: 24, hex: 0xE7C28D)
        fillRounded(ctx, CGRect(x: 112, y: 132, width: 408, height: 420), radius: 18, hex: 0xC46A34)
        drawText(ctx, "ISSUE 14 · AUTUMN", at: CGPoint(x: 620, y: rect.height - 120), size: 16, weight: .semibold, hex: 0x8F5E38)
        drawText(ctx, "Tactile", at: CGPoint(x: 616, y: rect.height - 220), size: 84, weight: .bold, hex: 0x261B14, serif: true)
        drawText(ctx, "Craft", at: CGPoint(x: 616, y: rect.height - 306), size: 84, weight: .bold, hex: 0x261B14, serif: true)
        for i in 0..<5 {
            fillRounded(ctx, CGRect(x: 620, y: 310 - CGFloat(i) * 34, width: 440 - CGFloat(i % 2) * 65, height: 14), radius: 7, hex: 0xD8CCB9)
        }
        drawText(ctx, "WARM PALETTE · EDITORIAL DESIGN", at: CGPoint(x: 620, y: 92), size: 16, weight: .medium, hex: 0x7A6655)
    }

    private static func drawCobaltHero(ctx: CGContext, rect: CGRect) {
        drawLinearGradient(ctx, rect: rect, topHex: 0x0A1638, bottomHex: 0x1E4CE8)
        fillCircle(ctx, center: CGPoint(x: rect.width * 0.5, y: rect.height * 0.12), radius: 420, hex: 0x4EA1FF, alpha: 0.28)
        fillRounded(ctx, CGRect(x: 490, y: rect.height - 160, width: 300, height: 42), radius: 21, hex: 0xFFFFFF, alpha: 0.14)
        drawText(ctx, "CLOUD AUTOMATION 3.0", at: CGPoint(x: 534, y: rect.height - 148), size: 16, weight: .semibold, hex: 0xD7E8FF)
        drawText(ctx, "Ship Faster With", at: CGPoint(x: 240, y: rect.height - 300), size: 88, weight: .bold, hex: 0xFFFFFF)
        drawText(ctx, "Direct Sync.", at: CGPoint(x: 360, y: rect.height - 404), size: 88, weight: .bold, hex: 0xA8CEFF)
        fillRounded(ctx, CGRect(x: 470, y: 180, width: 340, height: 74), radius: 37, hex: 0xFFFFFF)
        drawText(ctx, "Get Started →", at: CGPoint(x: 548, y: 204), size: 26, weight: .semibold, hex: 0x0E2469)
    }

    private static func drawBauhaus(ctx: CGContext, rect: CGRect) {
        fill(ctx, rect, hex: 0x1D1E22)
        fill(ctx, CGRect(x: 90, y: 90, width: 380, height: 380), hex: 0xE6A91A)
        fillCircle(ctx, center: CGPoint(x: 640, y: 620), radius: 210, hex: 0xDC3E2B)
        fill(ctx, CGRect(x: 470, y: 90, width: 380, height: 220), hex: 0x2663B8)
        fillCircle(ctx, center: CGPoint(x: 280, y: 280), radius: 105, hex: 0xF3EEE4)
        drawText(ctx, "BAUHAUS 1926", at: CGPoint(x: 96, y: 840), size: 42, weight: .bold, hex: 0xF3EEE4)
    }

    private static func drawEmeraldMobile(ctx: CGContext, rect: CGRect) {
        fill(ctx, rect, hex: 0x0B1512)
        drawLinearGradient(
            ctx,
            rect: CGRect(x: 54, y: rect.height - 420, width: rect.width - 108, height: 330),
            topHex: 0x10B981,
            bottomHex: 0x065F46,
            cornerRadius: 34
        )
        drawText(ctx, "TOTAL BALANCE", at: CGPoint(x: 96, y: rect.height - 165), size: 17, weight: .semibold, hex: 0xD1FAE5)
        drawText(ctx, "$84,290.50", at: CGPoint(x: 94, y: rect.height - 255), size: 64, weight: .bold, hex: 0xFFFFFF)
        drawText(ctx, "+12.4% THIS MONTH", at: CGPoint(x: 96, y: rect.height - 340), size: 18, weight: .medium, hex: 0xA7F3D0)
        for i in 0..<4 {
            let y = 520.0 - CGFloat(i) * 124.0
            fillRounded(ctx, CGRect(x: 54, y: y, width: rect.width - 108, height: 96), radius: 22, hex: 0x13221D)
            fillCircle(ctx, center: CGPoint(x: 112, y: y + 48), radius: 24, hex: i == 0 ? 0x34D399 : 0x1E3A30)
            fillRounded(ctx, CGRect(x: 158, y: y + 54, width: 220, height: 14), radius: 7, hex: 0xD8EDE5)
            fillRounded(ctx, CGRect(x: 158, y: y + 28, width: 140, height: 11), radius: 5, hex: 0x4E6E63)
        }
    }

    private static func drawMonochromeTerminal(ctx: CGContext, rect: CGRect) {
        fill(ctx, rect, hex: 0x111214)
        fillRounded(ctx, CGRect(x: 42, y: 42, width: rect.width - 84, height: rect.height - 84), radius: 20, hex: 0x191B1F)
        // Traffic lights
        fillCircle(ctx, center: CGPoint(x: 84, y: rect.height - 76), radius: 8, hex: 0xFF5F56)
        fillCircle(ctx, center: CGPoint(x: 110, y: rect.height - 76), radius: 8, hex: 0xFFBD2E)
        fillCircle(ctx, center: CGPoint(x: 136, y: rect.height - 76), radius: 8, hex: 0x27C93F)
        drawText(ctx, "chark — sync engine", at: CGPoint(x: 470, y: rect.height - 86), size: 18, weight: .medium, hex: 0x8E95A2, mono: true)
        let lines: [(String, UInt32)] = [
            ("$ gdirect scan --list", 0xE5E7EB),
            ("  173.194.77.100   OK   48 ms   [direct:en0]", 0x34D399),
            ("  142.251.36.113   OK   54 ms   [direct:en0]", 0x34D399),
            ("$ chark sync --root /Chark", 0xE5E7EB),
            ("  [index]  merged 146 items · 0 conflicts", 0x93C5FD),
            ("  [vision] OCR + feature prints indexed locally", 0xA78BFA),
            ("  [drive]  synced human-readable folders in 1.2s", 0x34D399)
        ]
        for (i, line) in lines.enumerated() {
            drawText(ctx, line.0, at: CGPoint(x: 84, y: rect.height - 170 - CGFloat(i) * 74), size: 24, weight: .medium, hex: line.1, mono: true)
        }
    }

    private static func drawCeramicGlazes(_ ctx: CGContext, _ rect: CGRect) {
        drawLinearGradient(ctx, rect: rect, topHex: 0xEBD8C0, bottomHex: 0xBE997C)
        drawText(ctx, "BISQUE / GLAZE", at: CGPoint(x: 64, y: 980), size: 70, weight: .bold, hex: 0x4C301F, serif: true)
        drawText(ctx, "KILN STUDY 03", at: CGPoint(x: 69, y: 926), size: 18, weight: .semibold, hex: 0x775444)
        let finishes: [(top: UInt32, bottom: UInt32, rim: UInt32)] = [
            (0xBD6C50, 0x753F2E, 0x633629),
            (0xCDAC83, 0x967151, 0x886147),
            (0x9A9B77, 0x555D49, 0x494F41)
        ]
        for (index, glaze) in finishes.enumerated() {
            let x = CGFloat(163 + index * 280)
            let base = CGFloat(384 + (index == 1 ? 68 : 0))
            let height = CGFloat([391, 282, 338][index])
            let lip = base + height
            ctx.setFillColor(cgColor(0x482E20, alpha: 0.21))
            ctx.fillEllipse(in: CGRect(x: x - 116, y: base - 28, width: 254, height: 55))
            let vessel = CGMutablePath()
            vessel.move(to: CGPoint(x: x - 59, y: lip))
            vessel.addCurve(to: CGPoint(x: x - 77, y: base),
                            control1: CGPoint(x: x - 148, y: lip - height * 0.45),
                            control2: CGPoint(x: x - 130, y: base + 31))
            vessel.addQuadCurve(to: CGPoint(x: x + 77, y: base), control: CGPoint(x: x, y: base - 24))
            vessel.addCurve(to: CGPoint(x: x + 59, y: lip),
                            control1: CGPoint(x: x + 130, y: base + 31),
                            control2: CGPoint(x: x + 148, y: lip - height * 0.45))
            vessel.closeSubpath()
            ctx.saveGState()
            ctx.addPath(vessel)
            ctx.clip()
            drawLinearGradient(ctx, rect: CGRect(x: x - 150, y: base - 28, width: 300, height: height + 48),
                               topHex: glaze.top, bottomHex: glaze.bottom)
            ctx.setStrokeColor(cgColor(0xF5D7B9, alpha: 0.29))
            ctx.setLineWidth(1.5)
            for line in 0..<25 {
                let y = base + 20 + Double(line) * (height - 45) / 25
                ctx.move(to: CGPoint(x: x - 146, y: y))
                ctx.addQuadCurve(to: CGPoint(x: x + 146, y: y + 6), control: CGPoint(x: x - 18, y: y - 14))
                ctx.strokePath()
            }
            ctx.restoreGState()
            ctx.setFillColor(cgColor(glaze.top))
            ctx.fillEllipse(in: CGRect(x: x - 62, y: lip - 19, width: 124, height: 39))
            ctx.setFillColor(cgColor(glaze.rim))
            ctx.fillEllipse(in: CGRect(x: x - 54, y: lip - 12, width: 108, height: 25))
        }
        fill(ctx, CGRect(x: 67, y: 224, width: 766, height: 2), hex: 0x89664F, alpha: 0.6)
        drawText(ctx, "01  OXIDE             02  SAND             03  CELADON", at: CGPoint(x: 68, y: 176),
                 size: 19, weight: .semibold, hex: 0x553829)
    }

    private static func drawArchitecture(_ ctx: CGContext, _ rect: CGRect) {
        fill(ctx, rect, hex: 0xD1AB7C)
        fill(ctx, CGRect(x: 0, y: 115, width: rect.width, height: 35), hex: 0xAE8965)
        for index in 0..<3 {
            let x = 72.0 + Double(index) * 366
            let wall = CGRect(x: x, y: 150, width: 320, height: 610)
            fill(ctx, wall, hex: [0xE2C29B, 0xD9B38B, 0xC89B71][index])
            fillRounded(ctx, CGRect(x: x + 54, y: 165, width: 210, height: 495), radius: 100, hex: 0x765943)
            fill(ctx, CGRect(x: x + 54, y: 165, width: 210, height: 285), hex: 0x765943)
            fill(ctx, CGRect(x: x + 72, y: 175, width: 90, height: 255), hex: 0x967759)
        }
        ctx.setFillColor(cgColor(0x594333, alpha: 0.28))
        ctx.move(to: CGPoint(x: 0, y: 115))
        ctx.addLine(to: CGPoint(x: 1050, y: 115))
        ctx.addLine(to: CGPoint(x: 0, y: 640))
        ctx.fillPath()
        drawText(ctx, "COURTYARD  /  03", at: CGPoint(x: 70, y: 63), size: 22, weight: .semibold, hex: 0x443126)
    }

    private static func drawBotanical(_ ctx: CGContext, _ rect: CGRect) {
        fill(ctx, rect, hex: 0xE8E5D5)
        ctx.setStrokeColor(cgColor(0xA39C81))
        ctx.setLineWidth(2)
        ctx.stroke(rect.insetBy(dx: 44, dy: 44))
        ctx.setStrokeColor(cgColor(0x66734E))
        ctx.setLineWidth(5)
        ctx.move(to: CGPoint(x: 310, y: 215))
        ctx.addQuadCurve(to: CGPoint(x: 540, y: 955), control: CGPoint(x: 550, y: 570))
        ctx.strokePath()
        for index in 0..<11 {
            let progress = Double(index) / 10
            let x = 361 + 191 * progress
            let y = 335 + 587 * progress
            let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
            ctx.saveGState()
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: direction * (0.62 + progress * 0.22))
            let length = 235 - progress * 90
            ctx.setFillColor(cgColor([0x80916E, 0xA2AD8C, 0x687A58][index % 3], alpha: 0.92))
            ctx.fillEllipse(in: CGRect(x: -32, y: 0, width: 66 - progress * 20, height: length))
            ctx.setStrokeColor(cgColor(0xEEF0DC, alpha: 0.7))
            ctx.setLineWidth(1.5)
            ctx.move(to: .zero)
            ctx.addLine(to: CGPoint(x: 0, y: length - 12))
            ctx.strokePath()
            ctx.restoreGState()
        }
        drawText(ctx, "Eucalyptus cinerea", at: CGPoint(x: 86, y: 116), size: 42, weight: .semibold, hex: 0x3F523A)
        drawText(ctx, "HERBARIUM  /  SILVER DOLLAR", at: CGPoint(x: 89, y: 78), size: 15, weight: .regular, hex: 0x58654D)
    }

    // MARK: - Drawing Primitives

    private static func cgColor(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, hex: UInt32, alpha: CGFloat = 1.0) {
        ctx.setFillColor(cgColor(hex, alpha: alpha))
        ctx.fill(rect)
    }

    private static func fillRounded(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, hex: UInt32, alpha: CGFloat = 1.0) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(cgColor(hex, alpha: alpha))
        ctx.fillPath()
    }

    private static func fillCircle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, hex: UInt32, alpha: CGFloat = 1.0) {
        ctx.setFillColor(cgColor(hex, alpha: alpha))
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func drawLinearGradient(
        _ ctx: CGContext,
        rect: CGRect,
        topHex: UInt32,
        bottomHex: UInt32,
        cornerRadius: CGFloat = 0
    ) {
        ctx.saveGState()
        if cornerRadius > 0 {
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.clip()
        } else {
            ctx.clip(to: rect)
        }
        let colors = [cgColor(topHex), cgColor(bottomHex)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: rect.minY),
                options: []
            )
        }
        ctx.restoreGState()
    }

    private enum FontWeight { case regular, medium, semibold, bold }

    private static func drawText(
        _ ctx: CGContext,
        _ text: String,
        at origin: CGPoint,
        size: CGFloat,
        weight: FontWeight,
        hex: UInt32,
        serif: Bool = false,
        mono: Bool = false
    ) {
        let fontName: String
        if serif {
            fontName = weight == .bold ? "Georgia-Bold" : "Georgia"
        } else if mono {
            fontName = "Menlo-Regular"
        } else {
            switch weight {
            case .regular: fontName = "HelveticaNeue"
            case .medium: fontName = "HelveticaNeue-Medium"
            case .semibold: fontName = "HelveticaNeue-Medium"
            case .bold: fontName = "HelveticaNeue-Bold"
            }
        }
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(hex)
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

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
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.86] : [:]
        CGImageDestinationAddImage(writer, image, options as CFDictionary)
        return CGImageDestinationFinalize(writer) ? data as Data : nil
    }

    static func color(_ hex: UInt32, alpha: Double = 1.0) -> CGColor {
        CGColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: alpha)
    }

    static func card(title: String, label: String, text: String, waveform: [Float] = []) -> CGImage? {
        guard let ctx = context(width: 800, height: 600) else { return nil }
        ctx.setFillColor(color(0xF6F4EF))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        ctx.setFillColor(color(0x2563EB))
        fillRoundedRect(CGRect(x: 46, y: 526, width: 24, height: 6), radius: 3, in: ctx)
        draw(label.uppercased(), in: ctx, at: CGPoint(x: 82, y: 520), size: 17, ink: 0x6B7280, width: 650, bold: true)
        draw(title, in: ctx, at: CGPoint(x: 46, y: 454), size: 36, ink: 0x18181B, width: 708, bold: true)
        ctx.setFillColor(color(0xE4E2DC))
        ctx.fill(CGRect(x: 46, y: 422, width: 708, height: 2))
        if waveform.isEmpty {
            let wrapped = wrapText(text, maxCharsPerLine: 42, maxLines: 10)
            for (index, line) in wrapped.enumerated() {
                draw(line, in: ctx, at: CGPoint(x: 46, y: 376 - index * 34),
                     size: 21, ink: 0x3F3F46, width: 708)
            }
        } else {
            let barCount = waveform.count
            let step = 708.0 / Double(max(1, barCount))
            for (index, peak) in waveform.enumerated() {
                let height = max(6, Double(peak) * 230)
                let barColor = index < barCount / 3 ? color(0x2563EB) : color(0x94A3B8)
                ctx.setFillColor(barColor)
                fillRoundedRect(
                    CGRect(x: 46 + Double(index) * step, y: 215 - height / 2, width: max(4, step * 0.58), height: height),
                    radius: max(2, step * 0.25),
                    in: ctx
                )
            }
        }
        return ctx.makeImage()
    }

    /// Editorial repository card for GitHub repositories.
    static func githubRepoCard(_ repo: GitHubRepoMetadata) -> CGImage? {
        guard let ctx = context(width: 820, height: 620) else { return nil }
        ctx.setFillColor(color(0x111317))
        ctx.fill(CGRect(x: 0, y: 0, width: 820, height: 620))

        // Subtle top border accent
        ctx.setFillColor(color(0x1E232B))
        fillRoundedRect(CGRect(x: 24, y: 24, width: 772, height: 572), radius: 22, in: ctx)

        // GitHub badge pill
        ctx.setFillColor(color(0x272D37))
        fillRoundedRect(CGRect(x: 52, y: 520, width: 132, height: 38), radius: 19, in: ctx)
        draw("GITHUB", in: ctx, at: CGPoint(x: 78, y: 531), size: 17, ink: 0xE4E8EE, width: 100, bold: true)

        if let lang = repo.language, !lang.isEmpty {
            ctx.setFillColor(color(0x60A5FA))
            ctx.fillEllipse(in: CGRect(x: 204, y: 533, width: 12, height: 12))
            draw(lang, in: ctx, at: CGPoint(x: 224, y: 531), size: 18, ink: 0x9CA3AF, width: 220, bold: false)
        }

        // Owner & Repo title
        draw(repo.owner + " /", in: ctx, at: CGPoint(x: 52, y: 462), size: 24, ink: 0x8B949E, width: 716, bold: false)
        draw(repo.repo, in: ctx, at: CGPoint(x: 52, y: 404), size: 46, ink: 0xF8FAFC, width: 716, bold: true)

        // Description
        let desc = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "GitHub 开源仓库 · 点击展开 README 文档"
        let descLines = wrapText(desc, maxCharsPerLine: 36, maxLines: 4)
        for (idx, line) in descLines.enumerated() {
            draw(line, in: ctx, at: CGPoint(x: 52, y: 342 - idx * 36), size: 23, ink: 0xCBD5E1, width: 716)
        }

        // Topics row
        var topicX: Double = 52
        for topic in repo.topics.prefix(4) {
            let pillWidth = min(190.0, Double(topic.count) * 11.5 + 32.0)
            if topicX + pillWidth > 768 { break }
            ctx.setFillColor(color(0x1D2D44))
            fillRoundedRect(CGRect(x: topicX, y: 146, width: pillWidth, height: 34), radius: 17, in: ctx)
            draw(topic, in: ctx, at: CGPoint(x: topicX + 16, y: 155), size: 16, ink: 0x93C5FD, width: pillWidth - 28, bold: true)
            topicX += pillWidth + 10
        }

        // Divider + Metrics footer
        ctx.setFillColor(color(0x2D333B))
        ctx.fill(CGRect(x: 52, y: 112, width: 716, height: 2))

        let starsText = "★ \(formatMetric(repo.stars))"
        let forksText = "⑂ \(formatMetric(repo.forks))"
        draw(starsText, in: ctx, at: CGPoint(x: 52, y: 64), size: 22, ink: 0xFACC15, width: 200, bold: true)
        draw(forksText, in: ctx, at: CGPoint(x: 230, y: 64), size: 22, ink: 0x9CA3AF, width: 200, bold: false)
        if let license = repo.licenseName, !license.isEmpty {
            draw(license, in: ctx, at: CGPoint(x: 420, y: 64), size: 20, ink: 0x6B7280, width: 220, bold: false)
        }
        if repo.readmeMarkdown?.isEmpty == false {
            ctx.setFillColor(color(0x2563EB))
            fillRoundedRect(CGRect(x: 646, y: 54, width: 122, height: 36), radius: 10, in: ctx)
            draw("README", in: ctx, at: CGPoint(x: 669, y: 64), size: 17, ink: 0xFFFFFF, width: 90, bold: true)
        }
        return ctx.makeImage()
    }

    /// Clean social post card (X / Threads / Bluesky) optionally compositing an embedded photo/video poster.
    static func socialPostCard(_ post: SocialPostMetadata, embeddedMedia: CGImage? = nil) -> CGImage? {
        let hasMedia = embeddedMedia != nil
        let width = 800
        let height = hasMedia ? 920 : 620
        guard let ctx = context(width: width, height: height) else { return nil }

        // Crisp paper-white social card matching reference Img 7 & light gallery feel
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Subtle outer hairline border
        ctx.setStrokeColor(color(0xE5E7EB))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))

        // Avatar circle + Author header
        let headerY = Double(height - 96)
        ctx.setFillColor(color(0x18181B))
        ctx.fillEllipse(in: CGRect(x: 44, y: headerY, width: 52, height: 52))
        let initial = String((post.authorName.first ?? post.authorHandle.first ?? "X")).uppercased()
        draw(initial, in: ctx, at: CGPoint(x: 62, y: headerY + 17), size: 22, ink: 0xFFFFFF, width: 32, bold: true)

        draw(post.authorName, in: ctx, at: CGPoint(x: 112, y: headerY + 26), size: 24, ink: 0x111827, width: 490, bold: true)
        var handleLine = "@\(post.authorHandle)"
        if let date = post.publishedAtText, !date.isEmpty {
            handleLine += " · \(String(date.prefix(16)))"
        }
        draw(handleLine, in: ctx, at: CGPoint(x: 112, y: headerY + 2), size: 17, ink: 0x6B7280, width: 500)

        // Platform badge top-right (sized tightly to platform name so "X" looks balanced)
        let badgeColor: UInt32 = switch post.platform {
        case .x: 0x18181B
        case .threads: 0x27272A
        case .bluesky: 0x0284C7
        }
        let badgeLabel = post.platform.displayName
        let badgeWidth: Double = max(46, Double(badgeLabel.count) * 12 + 28)
        let badgeX = Double(width) - 44 - badgeWidth
        ctx.setFillColor(color(badgeColor))
        fillRoundedRect(CGRect(x: badgeX, y: headerY + 10, width: badgeWidth, height: 34), radius: 17, in: ctx)
        let textInsetX = badgeLabel.count <= 2 ? (badgeWidth - 12) * 0.5 : 14
        draw(badgeLabel, in: ctx, at: CGPoint(x: badgeX + textInsetX, y: headerY + 19), size: 16, ink: 0xFFFFFF, width: badgeWidth - 12, bold: true)

        // Body text
        let bodyMaxLines = hasMedia ? 4 : 9
        let bodyLines = wrapText(post.bodyText, maxCharsPerLine: 34, maxLines: bodyMaxLines)
        var cursorY = headerY - 46
        for line in bodyLines {
            draw(line, in: ctx, at: CGPoint(x: 44, y: cursorY), size: 25, ink: 0x1F2937, width: 712)
            cursorY -= 38
        }

        // Embedded media preview (rounded aspect-fill)
        if let media = embeddedMedia {
            let mediaTop = min(cursorY + 6, Double(height) - 290)
            let mediaRect = CGRect(x: 44, y: 92, width: 712, height: max(220, mediaTop - 92))
            ctx.saveGState()
            addRoundedRectPath(mediaRect, radius: 18, in: ctx)
            ctx.clip()
            drawAspectFill(media, in: mediaRect, ctx: ctx)
            ctx.restoreGState()

            if post.hasVideo {
                ctx.setFillColor(color(0x000000, alpha: 0.62))
                ctx.fillEllipse(in: CGRect(x: mediaRect.midX - 36, y: mediaRect.midY - 36, width: 72, height: 72))
                ctx.setFillColor(color(0xFFFFFF))
                ctx.beginPath()
                ctx.move(to: CGPoint(x: mediaRect.midX - 10, y: mediaRect.midY - 16))
                ctx.addLine(to: CGPoint(x: mediaRect.midX - 10, y: mediaRect.midY + 16))
                ctx.addLine(to: CGPoint(x: mediaRect.midX + 18, y: mediaRect.midY))
                ctx.closePath()
                ctx.fillPath()
            }
        }

        // Footer engagement strip
        ctx.setFillColor(color(0xF3F4F6))
        ctx.fill(CGRect(x: 44, y: 66, width: 712, height: 1.5))
        var metrics: [String] = []
        if let r = post.replyCount { metrics.append("\(formatMetric(r)) 回复") }
        if let rt = post.repostCount { metrics.append("\(formatMetric(rt)) 转发") }
        if let l = post.likeCount { metrics.append("\(formatMetric(l)) 赞") }
        if let v = post.viewCount { metrics.append("\(formatMetric(v)) 浏览") }
        let footerText = metrics.isEmpty ? post.platform.openActionLabel : metrics.joined(separator: "   ")
        draw(footerText, in: ctx, at: CGPoint(x: 44, y: 30), size: 17, ink: 0x6B7280, width: 712)

        return ctx.makeImage()
    }

    /// Clean dark studio card fallback for 3D models that QuickLook/ModelIO cannot natively render (e.g. .blend/.fbx).
    static func model3DCard(title: String, format: String) -> CGImage? {
        guard let ctx = context(width: 800, height: 800) else { return nil }
        ctx.setFillColor(color(0x16181D))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 800))

        // Subtle wireframe isometric cube
        let cx = 400.0
        let cy = 440.0
        let r = 150.0
        let dx = r * 0.866
        let dy = r * 0.5
        let top = CGPoint(x: cx, y: cy + r)
        let tl = CGPoint(x: cx - dx, y: cy + dy)
        let tr = CGPoint(x: cx + dx, y: cy + dy)
        let center = CGPoint(x: cx, y: cy)
        let bl = CGPoint(x: cx - dx, y: cy - dy)
        let br = CGPoint(x: cx + dx, y: cy - dy)
        let bottom = CGPoint(x: cx, y: cy - r)

        // Top face
        ctx.setFillColor(color(0x2563EB, alpha: 0.28))
        ctx.beginPath()
        ctx.move(to: top); ctx.addLine(to: tr); ctx.addLine(to: center); ctx.addLine(to: tl); ctx.closePath()
        ctx.fillPath()
        // Left face
        ctx.setFillColor(color(0x1D4ED8, alpha: 0.20))
        ctx.beginPath()
        ctx.move(to: tl); ctx.addLine(to: center); ctx.addLine(to: bottom); ctx.addLine(to: bl); ctx.closePath()
        ctx.fillPath()
        // Right face
        ctx.setFillColor(color(0x60A5FA, alpha: 0.16))
        ctx.beginPath()
        ctx.move(to: tr); ctx.addLine(to: br); ctx.addLine(to: bottom); ctx.addLine(to: center); ctx.closePath()
        ctx.fillPath()

        ctx.setStrokeColor(color(0x60A5FA, alpha: 0.9))
        ctx.setLineWidth(3)
        ctx.beginPath()
        ctx.move(to: top); ctx.addLine(to: tr); ctx.addLine(to: br); ctx.addLine(to: bottom)
        ctx.addLine(to: bl); ctx.addLine(to: tl); ctx.closePath()
        ctx.move(to: tl); ctx.addLine(to: center); ctx.addLine(to: tr)
        ctx.move(to: center); ctx.addLine(to: bottom)
        ctx.strokePath()

        ctx.setFillColor(color(0x272B35))
        fillRoundedRect(CGRect(x: 48, y: 708, width: 126, height: 38), radius: 19, in: ctx)
        draw("3D · \(format.uppercased())", in: ctx, at: CGPoint(x: 68, y: 719), size: 17, ink: 0x93C5FD, width: 100, bold: true)
        draw(title, in: ctx, at: CGPoint(x: 48, y: 76), size: 32, ink: 0xF8FAFC, width: 704, bold: true)

        return ctx.makeImage()
    }

    static func swatch(_ swatch: LabColor) -> CGImage? {
        guard let ctx = context(width: 720, height: 620) else { return nil }
        ctx.setFillColor(color(UInt32(swatch.hex.dropFirst(), radix: 16) ?? 0x808080))
        ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 620))
        ctx.setFillColor(color(0xF7F3E9))
        ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 110))
        draw(swatch.hex, in: ctx, at: CGPoint(x: 42, y: 42), size: 31, ink: 0x25231F, width: 600, bold: true)
        return ctx.makeImage()
    }

    static func draw(_ text: String, in ctx: CGContext, at position: CGPoint, size: Double, ink: UInt32, width: Double, bold: Bool = false) {
        let uiType: CTFontUIFontType = bold ? .emphasizedSystem : .system
        let font = CTFontCreateUIFontForLanguage(uiType, size, nil)
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

    private static func fillRoundedRect(_ rect: CGRect, radius: Double, in ctx: CGContext) {
        addRoundedRectPath(rect, radius: radius, in: ctx)
        ctx.fillPath()
    }

    private static func addRoundedRectPath(_ rect: CGRect, radius: Double, in ctx: CGContext) {
        let r = min(radius, min(rect.width, rect.height) / 2)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        ctx.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        ctx.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        ctx.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        ctx.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        ctx.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        ctx.closePath()
    }

    private static func drawAspectFill(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let imgW = Double(image.width)
        let imgH = Double(image.height)
        guard imgW > 0, imgH > 0 else { return }
        let scale = max(rect.width / imgW, rect.height / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawRect = CGRect(
            x: rect.midX - drawW / 2,
            y: rect.midY - drawH / 2,
            width: drawW,
            height: drawH
        )
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
    }

    private static func wrapText(_ raw: String, maxCharsPerLine: Int, maxLines: Int) -> [String] {
        var result: [String] = []
        for paragraph in raw.components(separatedBy: .newlines) {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            var current = ""
            var currentWeight = 0
            for ch in trimmed {
                let w = ch.isASCII ? 1 : 2
                if currentWeight + w > maxCharsPerLine && !current.isEmpty {
                    result.append(current)
                    if result.count >= maxLines { return result }
                    current = String(ch)
                    currentWeight = w
                } else {
                    current.append(ch)
                    currentWeight += w
                }
            }
            if !current.isEmpty {
                result.append(current)
                if result.count >= maxLines { return result }
            }
        }
        return result
    }

    private static func formatMetric(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum MediaArtwork {
    private static let sRGBColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGBColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        default: return false
        }
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

    /// Editorial browser bookmark card fallback for arbitrary websites without an OpenGraph preview or WebKit snapshot.
    static func webPageCard(
        title: String,
        domain: String,
        siteName: String? = nil,
        description: String? = nil,
        urlString: String? = nil,
        themeColorHex: String? = nil,
        favicon: CGImage? = nil
    ) -> CGImage? {
        let width = 1200
        let height = 750
        guard let ctx = context(width: width, height: height) else { return nil }

        let accentHex = resolveWebCardAccentHex(themeColorHex: themeColorHex, domain: domain)

        // Subtle warm paper-studio backdrop matching Charkle gallery light surface
        ctx.setFillColor(color(0xF5F5F3))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Main elevated browser card
        let cardRect = CGRect(x: 34, y: 34, width: width - 68, height: height - 68)
        ctx.setFillColor(color(0xFFFFFF))
        fillRoundedRect(cardRect, radius: 28, in: ctx)
        ctx.setStrokeColor(color(0xE5E7EB))
        ctx.setLineWidth(2)
        addRoundedRectPath(cardRect, radius: 28, in: ctx)
        ctx.strokePath()

        // Top accent ribbon clipped inside card top edge
        ctx.saveGState()
        addRoundedRectPath(cardRect, radius: 28, in: ctx)
        ctx.clip()
        ctx.setFillColor(color(accentHex))
        ctx.fill(CGRect(x: cardRect.minX, y: cardRect.maxY - 12, width: cardRect.width, height: 12))
        ctx.restoreGState()

        // Browser-style header bar with favicon + site name / domain
        let headerY = 612.0
        let iconRect = CGRect(x: 78, y: headerY, width: 52, height: 52)
        if let favicon {
            ctx.saveGState()
            addRoundedRectPath(iconRect, radius: 13, in: ctx)
            ctx.clip()
            ctx.setFillColor(color(0xF3F4F6))
            ctx.fill(iconRect)
            drawAspectFill(favicon, in: iconRect.insetBy(dx: 4, dy: 4), ctx: ctx)
            ctx.restoreGState()
            ctx.setStrokeColor(color(0x000000, alpha: 0.08))
            ctx.setLineWidth(1.5)
            addRoundedRectPath(iconRect, radius: 13, in: ctx)
            ctx.strokePath()
        } else {
            ctx.setFillColor(color(accentHex, alpha: 0.14))
            fillRoundedRect(iconRect, radius: 13, in: ctx)
            let initial = String((domain.first ?? "W")).uppercased()
            draw(initial, in: ctx, at: CGPoint(x: 95, y: headerY + 15), size: 25, ink: accentHex, width: 32, bold: true)
        }

        let cleanSite = siteName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryHeader = (cleanSite?.isEmpty == false) ? cleanSite! : domain
        draw(primaryHeader, in: ctx, at: CGPoint(x: 148, y: headerY + 26), size: 22, ink: 0x111827, width: 760, bold: true)
        draw(domain, in: ctx, at: CGPoint(x: 148, y: headerY + 2), size: 17, ink: 0x6B7280, width: 760, bold: false)

        // Top-right WEB badge pill
        ctx.setFillColor(color(accentHex, alpha: 0.12))
        fillRoundedRect(CGRect(x: 1018, y: headerY + 8, width: 104, height: 36), radius: 18, in: ctx)
        draw("WEB", in: ctx, at: CGPoint(x: 1046, y: headerY + 18), size: 17, ink: accentHex, width: 64, bold: true)

        // Subtle divider below header
        ctx.setFillColor(color(0xF0F1F4))
        ctx.fill(CGRect(x: 78, y: 582, width: 1044, height: 2))

        // Main webpage title (up to 3 lines)
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? domain : title
        let titleLines = wrapText(displayTitle, maxCharsPerLine: 26, maxLines: 3)
        var cursorY = 506.0
        for line in titleLines {
            draw(line, in: ctx, at: CGPoint(x: 78, y: cursorY), size: 46, ink: 0x111827, width: 1044, bold: true)
            cursorY -= 62
        }

        // Meta description excerpt (up to 3 lines)
        let cleanDesc = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanDesc.isEmpty {
            let descLines = wrapText(cleanDesc, maxCharsPerLine: 44, maxLines: 3)
            var descY = min(cursorY - 10, 326.0)
            for line in descLines {
                draw(line, in: ctx, at: CGPoint(x: 78, y: descY), size: 24, ink: 0x4B5563, width: 1044)
                descY -= 38
            }
        }

        // Footer bar with full URL & browser-open indicator
        ctx.setFillColor(color(0xF0F1F4))
        ctx.fill(CGRect(x: 78, y: 128, width: 1044, height: 2))

        let footerURL = urlString ?? "https://\(domain)"
        draw(footerURL, in: ctx, at: CGPoint(x: 78, y: 76), size: 19, ink: 0x6B7280, width: 790)

        ctx.setFillColor(color(0x111827))
        fillRoundedRect(CGRect(x: 912, y: 62, width: 210, height: 44), radius: 22, in: ctx)
        draw("↗ 默认浏览器打开", in: ctx, at: CGPoint(x: 938, y: 76), size: 18, ink: 0xFFFFFF, width: 170, bold: true)

        return ctx.makeImage()
    }

    private static func resolveWebCardAccentHex(themeColorHex: String?, domain: String) -> UInt32 {
        if let raw = themeColorHex?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("#"),
           let parsed = UInt32(raw.dropFirst(), radix: 16) {
            let r = Int((parsed >> 16) & 255)
            let g = Int((parsed >> 8) & 255)
            let b = Int(parsed & 255)
            let lum = (r * 299 + g * 587 + b * 114) / 1000
            // Avoid near-white theme colors disappearing against the white card.
            if lum < 215 && lum > 22 {
                return parsed
            }
        }
        let palette: [UInt32] = [0x2563EB, 0x0F766E, 0x4F46E5, 0xB45309, 0x0369A1, 0x7C3AED, 0xBE123C, 0x334155]
        let hash = domain.utf8.reduce(UInt64(5381)) { (($0 &<< 5) &+ $0) &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// Clean social post card (X / Threads / Bluesky / Xiaohongshu).
    /// Xiaohongshu notes render as native 3:4 cover posters (`900x1200`) matching the platform's default cover ratio;
    /// X / Threads / Bluesky keep the text-first card layout.
    static func socialPostCard(
        _ post: SocialPostMetadata,
        embeddedMedia: CGImage? = nil,
        authorAvatar: CGImage? = nil
    ) -> CGImage? {
        if post.platform == .xiaohongshu {
            return xiaohongshuPostCard(post, embeddedMedia: embeddedMedia, authorAvatar: authorAvatar)
        }
        if post.platform.isVideoPlatform {
            return videoPlatformCard(post, embeddedMedia: embeddedMedia, authorAvatar: authorAvatar)
        }

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

        // Avatar circle (real author photo when fetched, crisp monogram fallback when offline)
        let headerY = Double(height - 96)
        let avatarRect = CGRect(x: 44, y: headerY, width: 52, height: 52)
        if let authorAvatar {
            ctx.saveGState()
            ctx.addEllipse(in: avatarRect)
            ctx.clip()
            drawAspectFill(authorAvatar, in: avatarRect, ctx: ctx)
            ctx.restoreGState()
            ctx.setStrokeColor(color(0x000000, alpha: 0.08))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: avatarRect.insetBy(dx: 0.75, dy: 0.75))
        } else {
            ctx.setFillColor(color(0x18181B))
            ctx.fillEllipse(in: avatarRect)
            let initial = String((post.authorName.first ?? post.authorHandle.first ?? "X")).uppercased()
            draw(initial, in: ctx, at: CGPoint(x: 62, y: headerY + 17), size: 22, ink: 0xFFFFFF, width: 32, bold: true)
        }

        // Leave clean breathing room on the top-right where the gallery's floating platform badge sits
        // (avoids colliding double badges on masonry thumbnails).
        draw(post.authorName, in: ctx, at: CGPoint(x: 112, y: headerY + 26), size: 24, ink: 0x111827, width: 540, bold: true)
        var handleParts: [String] = []
        if let handleLine = post.displayHandleLine {
            handleParts.append(handleLine)
        } else {
            handleParts.append(post.platform.displayName)
        }
        if let date = post.publishedAtText, !date.isEmpty {
            handleParts.append(String(date.prefix(16)))
        }
        draw(handleParts.joined(separator: " · "), in: ctx, at: CGPoint(x: 112, y: headerY + 2), size: 17, ink: 0x6B7280, width: 560)

        // Optional bold article/note headline + Body text
        var cursorY = headerY - 46
        var remainingBodyLines = hasMedia ? 4 : 9
        if let headline = post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
            let headLines = wrapText(headline, maxCharsPerLine: 26, maxLines: 2)
            for line in headLines {
                draw(line, in: ctx, at: CGPoint(x: 44, y: cursorY), size: 27, ink: 0x111827, width: 712, bold: true)
                cursorY -= 38
                remainingBodyLines = max(1, remainingBodyLines - 1)
            }
            cursorY -= 4
        }
        let bodySource = post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldDrawBody = !bodySource.isEmpty && bodySource != post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldDrawBody {
            let bodyLines = wrapText(bodySource, maxCharsPerLine: 34, maxLines: remainingBodyLines)
            for line in bodyLines {
                draw(line, in: ctx, at: CGPoint(x: 44, y: cursorY), size: 24, ink: 0x1F2937, width: 712)
                cursorY -= 36
            }
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

    /// Crisp 16:9 video bookmark card (`960x760`) for YouTube and Bilibili:
    /// - Top (`960x540`): full-bleed 16:9 video cover with play badge, duration pill, and optional AI summary indicator.
    /// - Bottom (`220px`): paper-white footer with 2-line video title, creator avatar + name, and view/like metrics.
    private static func videoPlatformCard(
        _ post: SocialPostMetadata,
        embeddedMedia: CGImage?,
        authorAvatar: CGImage?
    ) -> CGImage? {
        let width = 960
        let coverHeight = 540
        let footerHeight = 220
        let height = coverHeight + footerHeight
        guard let ctx = context(width: width, height: height) else { return nil }

        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fill(canvasRect)

        let coverRect = CGRect(x: 0, y: footerHeight, width: width, height: coverHeight)
        if let media = embeddedMedia {
            ctx.saveGState()
            ctx.clip(to: coverRect)
            ctx.setFillColor(color(0x16181D))
            ctx.fill(coverRect)
            drawAspectFill(media, in: coverRect, ctx: ctx)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(color(0x1E2025))
            ctx.fill(coverRect)
        }

        // Centered translucent play circle
        let playSize: Double = 78
        let playRect = CGRect(
            x: coverRect.midX - playSize / 2,
            y: coverRect.midY - playSize / 2,
            width: playSize,
            height: playSize
        )
        ctx.setFillColor(color(0x000000, alpha: 0.56))
        ctx.fillEllipse(in: playRect)
        ctx.setStrokeColor(color(0xFFFFFF, alpha: 0.40))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: playRect.insetBy(dx: 1, dy: 1))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: coverRect.midX - 11, y: coverRect.midY - 17))
        ctx.addLine(to: CGPoint(x: coverRect.midX - 11, y: coverRect.midY + 17))
        ctx.addLine(to: CGPoint(x: coverRect.midX + 20, y: coverRect.midY))
        ctx.closePath()
        ctx.fillPath()

        // Top-left AI summary badge when video summary/chapters exist
        if post.hasVideoSummaryContent {
            let pillRect = CGRect(x: 24, y: Double(height - 68), width: 124, height: 42)
            ctx.setFillColor(color(0x111827, alpha: 0.72))
            addRoundedRectPath(pillRect, radius: 21, in: ctx)
            ctx.fillPath()
            draw("含视频摘要", in: ctx, at: CGPoint(x: 42, y: Double(height - 58)), size: 18, ink: 0xFFFFFF, width: 100, bold: true)
        }

        // Bottom-right duration pill
        if let durText = post.formattedVideoDuration {
            let pillW = max(84.0, Double(durText.count) * 14.0 + 28.0)
            let pillRect = CGRect(x: Double(width) - pillW - 22, y: Double(footerHeight) + 18, width: pillW, height: 38)
            ctx.setFillColor(color(0x000000, alpha: 0.76))
            addRoundedRectPath(pillRect, radius: 10, in: ctx)
            ctx.fillPath()
            draw(durText, in: ctx, at: CGPoint(x: pillRect.minX + 14, y: pillRect.minY + 9), size: 19, ink: 0xFFFFFF, width: pillW - 20, bold: true)
        }

        // Footer: Bold 2-line video title
        let headline = post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleLines = wrapText(headline.isEmpty ? post.platform.postTypeLabel : headline, maxCharsPerLine: 28, maxLines: 2)
        var titleY = Double(footerHeight) - 56
        for line in titleLines {
            draw(line, in: ctx, at: CGPoint(x: 32, y: titleY), size: 28, ink: 0x111827, width: Double(width - 64), bold: true)
            titleY -= 40
        }

        // Footer bottom row: Creator avatar + name + metrics
        let avatarRect = CGRect(x: 32, y: 26, width: 44, height: 44)
        let brandHex: UInt32 = post.platform == .bilibili ? 0xFB7299 : 0xFF0000
        if let authorAvatar {
            ctx.saveGState()
            ctx.addEllipse(in: avatarRect)
            ctx.clip()
            drawAspectFill(authorAvatar, in: avatarRect, ctx: ctx)
            ctx.restoreGState()
            ctx.setStrokeColor(color(0x000000, alpha: 0.08))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: avatarRect.insetBy(dx: 0.75, dy: 0.75))
        } else {
            ctx.setFillColor(color(brandHex))
            ctx.fillEllipse(in: avatarRect)
            let initial = String((post.authorName.first ?? "V")).uppercased()
            draw(initial, in: ctx, at: CGPoint(x: 46, y: 39), size: 19, ink: 0xFFFFFF, width: 26, bold: true)
        }

        draw(post.authorName, in: ctx, at: CGPoint(x: 88, y: 37), size: 22, ink: 0x374151, width: 480, bold: true)

        var metrics: [String] = []
        if let views = post.viewCount { metrics.append("\(formatMetric(views)) 播放") }
        if let likes = post.likeCount { metrics.append("\(formatMetric(likes)) 赞") }
        let rightLabel = metrics.isEmpty ? post.platform.displayName : metrics.joined(separator: " · ")
        draw(rightLabel, in: ctx, at: CGPoint(x: 590, y: 38), size: 19, ink: 0x6B7280, width: 338)

        ctx.setStrokeColor(color(0xE5E7EB))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))

        return ctx.makeImage()
    }

    /// Native Xiaohongshu feed card (`900x1440`):
    /// - Top: strict vertical 3:4 (`900x1200`) full-bleed cover image with multi-image / video indicators.
    /// - Bottom (`240px`): crisp paper-white footer preserving the bold note title (up to 2 lines),
    ///   author circular avatar + name, and right-aligned like count.
    private static func xiaohongshuPostCard(
        _ post: SocialPostMetadata,
        embeddedMedia: CGImage?,
        authorAvatar: CGImage?
    ) -> CGImage? {
        let width = 900
        let coverHeight = 1_200 // Strict 3:4 vertical cover (900 x 1200)
        let footerHeight = 240
        let height = coverHeight + footerHeight // 900 x 1440 (ratio 0.625, unclipped in masonry)
        guard let ctx = context(width: width, height: height) else { return nil }

        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fill(canvasRect)

        if let media = embeddedMedia {
            // 1. Top strict 3:4 cover photo (y = 240 ... 1440)
            let coverRect = CGRect(x: 0, y: footerHeight, width: width, height: coverHeight)
            ctx.saveGState()
            ctx.clip(to: coverRect)
            ctx.setFillColor(color(0xF5F5F3))
            ctx.fill(coverRect)
            drawAspectFill(media, in: coverRect, ctx: ctx)
            ctx.restoreGState()

            // Multi-image indicator pill on top-left (leaves top-right clear for Charkle's floating platform badge)
            let mediaCount = post.effectiveAttachments.count
            if mediaCount > 1 && !post.hasVideo {
                let label = "\(mediaCount) 图"
                let pillRect = CGRect(x: 24, y: Double(height - 72), width: 96, height: 44)
                ctx.setFillColor(color(0x111827, alpha: 0.66))
                fillRoundedRect(pillRect, radius: 22, in: ctx)
                draw(label, in: ctx, at: CGPoint(x: 44, y: Double(height - 58)), size: 20, ink: 0xFFFFFF, width: 68, bold: true)
            }

            if post.hasVideo {
                ctx.setFillColor(color(0x000000, alpha: 0.58))
                ctx.fillEllipse(in: CGRect(x: coverRect.midX - 44, y: coverRect.midY - 44, width: 88, height: 88))
                ctx.setFillColor(color(0xFFFFFF))
                ctx.beginPath()
                ctx.move(to: CGPoint(x: coverRect.midX - 12, y: coverRect.midY - 20))
                ctx.addLine(to: CGPoint(x: coverRect.midX - 12, y: coverRect.midY + 20))
                ctx.addLine(to: CGPoint(x: coverRect.midX + 22, y: coverRect.midY))
                ctx.closePath()
                ctx.fillPath()
            }

            // Hairline divider separating light cover photos from the white title footer
            ctx.setFillColor(color(0xEFEFEF))
            ctx.fill(CGRect(x: 0, y: Double(footerHeight) - 1.5, width: Double(width), height: 1.5))

            // 2. Bottom Xiaohongshu title + author + likes footer (y = 0 ... 240)
            let rawTitle = (post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = rawTitle.isEmpty ? "\(post.authorName) 的小红书笔记" : rawTitle
            let titleLines = wrapText(displayTitle, maxCharsPerLine: 25, maxLines: 2)
            var titleY = titleLines.count > 1 ? 182.0 : 158.0
            for line in titleLines {
                draw(line, in: ctx, at: CGPoint(x: 34, y: titleY), size: 32, ink: 0x18191C, width: 832, bold: true)
                titleY -= 46
            }

            // Author avatar + nickname + right-aligned likes row
            let avatarRect = CGRect(x: 34, y: 34, width: 42, height: 42)
            if let authorAvatar {
                ctx.saveGState()
                ctx.addEllipse(in: avatarRect)
                ctx.clip()
                drawAspectFill(authorAvatar, in: avatarRect, ctx: ctx)
                ctx.restoreGState()
                ctx.setStrokeColor(color(0x000000, alpha: 0.08))
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: avatarRect.insetBy(dx: 0.6, dy: 0.6))
            } else {
                ctx.setFillColor(color(0xFF2442, alpha: 0.14))
                ctx.fillEllipse(in: avatarRect)
                let initial = String((post.authorName.first ?? "小")).uppercased()
                draw(initial, in: ctx, at: CGPoint(x: 46, y: 46), size: 20, ink: 0xFF2442, width: 24, bold: true)
            }

            var rightLabelWidth = 0.0
            if let likes = post.likeCount {
                let likesText = "♥ \(formatMetric(likes))"
                rightLabelWidth = drawRightAligned(likesText, in: ctx, rightX: Double(width - 34), baselineY: 46, size: 22, ink: 0x6B7280, maxWidth: 180)
            }

            let authorMaxW = max(240, Double(width - 34) - 90 - (rightLabelWidth > 0 ? rightLabelWidth + 20 : 0))
            draw(post.authorName, in: ctx, at: CGPoint(x: 90, y: 46), size: 23, ink: 0x5C6069, width: authorMaxW)

            // Crisp outer hairline border so white footer edges stay distinct on light canvas
            ctx.setStrokeColor(color(0xE5E7EB))
            ctx.setLineWidth(2)
            ctx.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))

            return ctx.makeImage()
        }

        // Clean 900x1440 editorial fallback card when cover media is unavailable
        ctx.setFillColor(color(0xFF2442))
        ctx.fill(CGRect(x: 0, y: Double(height - 12), width: Double(width), height: 12))

        ctx.setStrokeColor(color(0xE5E7EB))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))

        let headerY = Double(height - 118)
        let avatarRect = CGRect(x: 52, y: headerY, width: 58, height: 58)
        if let authorAvatar {
            ctx.saveGState()
            ctx.addEllipse(in: avatarRect)
            ctx.clip()
            drawAspectFill(authorAvatar, in: avatarRect, ctx: ctx)
            ctx.restoreGState()
            ctx.setStrokeColor(color(0x000000, alpha: 0.08))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: avatarRect.insetBy(dx: 0.75, dy: 0.75))
        } else {
            ctx.setFillColor(color(0xFF2442))
            ctx.fillEllipse(in: avatarRect)
            let initial = String((post.authorName.first ?? "小")).uppercased()
            draw(initial, in: ctx, at: CGPoint(x: 68, y: headerY + 18), size: 26, ink: 0xFFFFFF, width: 36, bold: true)
        }

        draw(post.authorName, in: ctx, at: CGPoint(x: 128, y: headerY + 30), size: 27, ink: 0x111827, width: 590, bold: true)
        var subParts: [String] = []
        if let handleLine = post.displayHandleLine {
            subParts.append(handleLine)
        } else {
            subParts.append(post.platform.displayName)
        }
        if let date = post.publishedAtText, !date.isEmpty {
            subParts.append(String(date.prefix(16)))
        }
        draw(subParts.joined(separator: " · "), in: ctx, at: CGPoint(x: 128, y: headerY + 2), size: 19, ink: 0x6B7280, width: 620)

        ctx.setFillColor(color(0xF3F4F6))
        ctx.fill(CGRect(x: 52, y: headerY - 26, width: 796, height: 2))

        var cursorY = headerY - 82
        if let headline = post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
            let headLines = wrapText(headline, maxCharsPerLine: 22, maxLines: 3)
            for line in headLines {
                draw(line, in: ctx, at: CGPoint(x: 52, y: cursorY), size: 36, ink: 0x111827, width: 796, bold: true)
                cursorY -= 50
            }
            cursorY -= 12
        }

        let bodySource = post.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldDrawBody = !bodySource.isEmpty && bodySource != post.articleTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldDrawBody {
            let bodyLines = wrapText(bodySource, maxCharsPerLine: 30, maxLines: 16)
            for line in bodyLines {
                if cursorY < 130 { break }
                draw(line, in: ctx, at: CGPoint(x: 52, y: cursorY), size: 26, ink: 0x374151, width: 796)
                cursorY -= 42
            }
        }

        ctx.setFillColor(color(0xF3F4F6))
        ctx.fill(CGRect(x: 52, y: 84, width: 796, height: 2))
        var metrics: [String] = []
        if let l = post.likeCount { metrics.append("\(formatMetric(l)) 赞") }
        if let rt = post.repostCount { metrics.append("\(formatMetric(rt)) 收藏") }
        if let r = post.replyCount { metrics.append("\(formatMetric(r)) 评论") }
        let footerText = metrics.isEmpty ? post.platform.openActionLabel : metrics.joined(separator: "   ")
        draw(footerText, in: ctx, at: CGPoint(x: 52, y: 38), size: 20, ink: 0x6B7280, width: 796)

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

    @discardableResult
    private static func drawRightAligned(
        _ text: String,
        in ctx: CGContext,
        rightX: Double,
        baselineY: Double,
        size: Double,
        ink: UInt32,
        maxWidth: Double,
        bold: Bool = false
    ) -> Double {
        let uiType: CTFontUIFontType = bold ? .emphasizedSystem : .system
        let font = CTFontCreateUIFontForLanguage(uiType, size, nil)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(ink)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let visible = CTLineCreateTruncatedLine(line, maxWidth, .end, ellipsis) ?? line
        let lineWidth = CTLineGetTypographicBounds(visible, nil, nil, nil)
        ctx.textPosition = CGPoint(x: rightX - lineWidth, y: baselineY)
        CTLineDraw(visible, ctx)
        return lineWidth
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

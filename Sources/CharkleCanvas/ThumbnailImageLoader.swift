import AppKit
import CharkleCore
import ImageIO
import SwiftUI

/// Async cached thumbnail loader using `NSCache<NSString, NSImage>` with in-flight deduplication
/// and off-main-thread hardware-accelerated ImageIO downsampling.
@Observable
public final class ThumbnailImageLoader {
    private let engine: any CharkleEngineProtocol
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var revision: Int = 0

    public init(engine: any CharkleEngineProtocol, maxCount: Int = 600, maxCostBytes: Int = 180 * 1024 * 1024) {
        self.engine = engine
        cache.countLimit = maxCount
        cache.totalCostLimit = maxCostBytes
    }

    private func cacheKey(assetID: UUID, tier: ThumbnailTier) -> String {
        "\(assetID.uuidString)-\(tier.rawValue)"
    }

    public func cachedImage(for assetID: UUID, tier: ThumbnailTier = .grid520) -> NSImage? {
        cache.object(forKey: cacheKey(assetID: assetID, tier: tier) as NSString)
    }

    public func loadImage(for assetID: UUID, tier: ThumbnailTier = .grid520) async -> NSImage? {
        let key = cacheKey(assetID: assetID, tier: tier)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let engine = self.engine
        let maxPixel = tier == .grid520 ? 520 : 1400
        let task = Task<NSImage?, Never> {
            guard let url = await engine.thumbnailURL(for: assetID, tier: tier) else {
                return nil
            }
            return await Self.decodeImage(from: url, maxPixelSize: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight.removeValue(forKey: key)

        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
            revision &+= 1
        }
        return image
    }

    public func invalidate(assetID: UUID) {
        for tier in [ThumbnailTier.grid520, .preview1400] {
            let key = cacheKey(assetID: assetID, tier: tier)
            cache.removeObject(forKey: key as NSString)
            inFlight[key]?.cancel()
            inFlight.removeValue(forKey: key)
        }
    }

    public func clearMemoryCache() {
        cache.removeAllObjects()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        revision &+= 1
    }

    @concurrent
    private static func decodeImage(from url: URL, maxPixelSize: Int) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return NSImage(contentsOf: url)
    }
}

// MARK: - Gallery-Grade Media Thumbnail Surface (With Procedural 7-Kind Fallbacks)

public struct AssetThumbnailSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    public let asset: AssetRecord
    public let loader: ThumbnailImageLoader
    public let tier: ThumbnailTier
    public let cornerRadius: CGFloat
    public let isHovered: Bool
    public let crop: NormalizedCropRect?

    @State private var loadedImage: NSImage?

    public init(
        asset: AssetRecord,
        loader: ThumbnailImageLoader,
        tier: ThumbnailTier = .grid520,
        cornerRadius: CGFloat = 12,
        isHovered: Bool = false,
        crop: NormalizedCropRect? = nil
    ) {
        self.asset = asset
        self.loader = loader
        self.tier = tier
        self.cornerRadius = cornerRadius
        self.isHovered = isHovered
        self.crop = crop
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .overlay {
                if let image = loadedImage ?? loader.cachedImage(for: asset.id, tier: tier) {
                    croppedImageView(image)
                } else {
                    ProceduralMediaFallbackCard(asset: asset, isHovered: isHovered)
                }
            }
            .clipped()
            .clipShape(shape)
            .contentShape(shape)
            .task(id: "\(asset.id.uuidString)-\(tier.rawValue)") {
                if let cached = loader.cachedImage(for: asset.id, tier: tier) {
                    loadedImage = cached
                    return
                }
                let img = await loader.loadImage(for: asset.id, tier: tier)
                if !Task.isCancelled {
                    loadedImage = img
                }
            }
    }

    @ViewBuilder
    private func croppedImageView(_ image: NSImage) -> some View {
        if let crop, crop != .full, crop.width > 0.05, crop.height > 0.05 {
            GeometryReader { geo in
                let scaleX = 1.0 / crop.width
                let scaleY = 1.0 / crop.height
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width * scaleX, height: geo.size.height * scaleY)
                    .offset(x: -geo.size.width * crop.x * scaleX, y: -geo.size.height * crop.y * scaleY)
            }
            .clipped()
        } else {
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
    }
}

/// Tasteful gallery-grade procedural preview cards for all 7 `MediaKind`s when no raster thumbnail
/// exists yet (e.g., audio waveforms, color swatches, web bookmarks, PDFs, design files, or offline placeholders).
public struct ProceduralMediaFallbackCard: View {
    @Environment(\.colorScheme) private var colorScheme

    public let asset: AssetRecord
    public let isHovered: Bool

    public init(asset: AssetRecord, isHovered: Bool = false) {
        self.asset = asset
        self.isHovered = isHovered
    }

    private var primaryHex: String {
        asset.dominantColors.first?.hex ?? (colorScheme == .dark ? "#2B2F36" : "#DCDAD4")
    }

    private var secondaryHex: String {
        if asset.dominantColors.count > 1 {
            return asset.dominantColors[1].hex
        }
        return colorScheme == .dark ? "#1E2126" : "#EAE8E2"
    }

    private var isColorSwatchAsset: Bool {
        asset.fileName.lowercased().hasSuffix(".swatch")
    }

    public var body: some View {
        Group {
            if isColorSwatchAsset {
                colorSwatchCard
            } else {
                switch asset.mediaKind {
                case .image:
                    editorialImagePlaceholder
                case .animatedImage:
                    animatedImagePlaceholder
                case .video:
                    videoPlaceholder
                case .audio:
                    audioWaveformCard
                case .webBookmark:
                    webBookmarkCard
                case .document:
                    documentCard
                case .designFile:
                    designFileCard
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var colorSwatchCard: some View {
        let hex = primaryHex
        let light = Color.charkleIsLightHex(hex)
        return ZStack(alignment: .bottomLeading) {
            Color(charkleHex: hex)
            VStack(alignment: .leading, spacing: 2) {
                Text(hex.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(light ? Color.black.opacity(0.84) : Color.white.opacity(0.92))
                if asset.title.uppercased() != hex.uppercased() {
                    Text(asset.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(light ? Color.black.opacity(0.60) : Color.white.opacity(0.70))
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
    }

    private var editorialImagePlaceholder: some View {
        let p = Color(charkleHex: primaryHex)
        let s = Color(charkleHex: secondaryHex)
        return ZStack {
            LinearGradient(
                colors: [p.opacity(0.88), s.opacity(0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Subtle architectural paper grain block
            GeometryReader { geo in
                let minSide = min(geo.size.width, geo.size.height)
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: minSide * 0.72, height: minSide * 0.72)
                    .offset(x: geo.size.width * 0.45, y: -minSide * 0.22)
                    .blur(radius: 18)
            }
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Color.charkleIsLightHex(primaryHex) ? Color.black.opacity(0.45) : Color.white.opacity(0.55))
                if asset.dominantColors.count >= 2 {
                    HStack(spacing: 4) {
                        ForEach(asset.dominantColors.prefix(4), id: \.hex) { swatch in
                            Circle()
                                .fill(Color(charkleHex: swatch.hex))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5))
                        }
                    }
                }
            }
        }
    }

    private var animatedImagePlaceholder: some View {
        ZStack {
            editorialImagePlaceholder
            VStack(spacing: 6) {
                Image(systemName: isHovered ? "play.circle.fill" : "sparkles.rectangle.stack")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                Text("GIF / MOTION")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
    }

    private var videoPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(charkleHex: primaryHex).opacity(0.65), Color(charkleHex: "#17191D")],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.42))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75))
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
                Text(CanvasFormatters.durationString(asset.durationSeconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private var audioWaveformCard: some View {
        let peaks = resolvedPeaks
        let barColor = Color(charkleHex: primaryHex)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(barColor)
                Spacer()
                Text(CanvasFormatters.durationString(asset.durationSeconds))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            GeometryReader { geo in
                let barCount = min(peaks.count, max(16, Int(geo.size.width / 5)))
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<barCount, id: \.self) { idx in
                        let sampleIndex = idx * peaks.count / max(barCount, 1)
                        let amp = max(0.14, min(1.0, CGFloat(peaks[sampleIndex])))
                        Capsule(style: .continuous)
                            .fill(barColor.opacity(0.55 + Double(amp) * 0.45))
                            .frame(height: max(4, geo.size.height * amp))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 38, maxHeight: 56)

            Spacer(minLength: 4)

            Text(asset.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(14)
        .background(CanvasSurface.elevated(for: colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 1)
        )
    }

    private var resolvedPeaks: [Float] {
        if !asset.waveformPeaks.isEmpty {
            return asset.waveformPeaks
        }
        // Deterministic calm waveform from asset UUID
        let bytes = withUnsafeBytes(of: asset.id.uuid) { Array($0) }
        return (0..<32).map { i in
            let seed = Double(bytes[i % bytes.count]) / 255.0
            let envelope = sin(Double(i) / 31.0 * .pi)
            return Float(0.2 + 0.75 * envelope * (0.45 + 0.55 * seed))
        }
    }

    private var webBookmarkCard: some View {
        let accent = Color(charkleHex: primaryHex)
        let domain = asset.sourceDomain
            ?? asset.sourceURL.flatMap { URL(string: $0)?.host }
            ?? "web.link"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(domain)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Text(asset.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            if !asset.notes.isEmpty {
                Text(asset.notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 2)
        }
        .padding(14)
        .background(CanvasSurface.elevated(for: colorScheme))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(accent.opacity(0.8))
                .frame(height: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 1)
        )
    }

    private var documentCard: some View {
        let ext = CanvasFormatters.fileExtensionBadge(for: asset.fileName)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ext)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer()
                Image(systemName: "doc.richtext")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Text(asset.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !asset.notes.isEmpty {
                Text(asset.notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.10)).frame(height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08)).frame(width: 96, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)).frame(width: 72, height: 5)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(CanvasSurface.elevated(for: colorScheme))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 1)
        )
    }

    private var designFileCard: some View {
        let ext = CanvasFormatters.fileExtensionBadge(for: asset.fileName)
        let accent = Color(charkleHex: primaryHex)
        return ZStack {
            CanvasSurface.elevated(for: colorScheme)
            // Subtle drafting crosshair lines
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width * 0.5, y: 12))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.5, y: geo.size.height - 12))
                    path.move(to: CGPoint(x: 12, y: geo.size.height * 0.5))
                    path.addLine(to: CGPoint(x: geo.size.width - 12, y: geo.size.height * 0.5))
                }
                .stroke(Color.primary.opacity(0.05), style: StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
            }
            VStack(spacing: 8) {
                Text(ext)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.charkleIsLightHex(primaryHex) ? Color.black.opacity(0.86) : Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(asset.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(CanvasSurface.hairline(for: colorScheme), lineWidth: 1)
        )
    }
}

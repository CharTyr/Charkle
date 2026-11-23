import AppKit
import CharkleCore
import ImageIO
import SwiftUI

/// Bounded LIFO concurrency gate for off-main-thread thumbnail decoding.
/// Prioritizes the most recently scrolled-into-view cards and immediately drops
/// cancelled waiters when cards scroll offscreen during fast trackpad flings.
private actor ThumbnailDecodeScheduler {
    private let maxConcurrent: Int
    private var running: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(maxConcurrent: Int = 6) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < maxConcurrent {
            running += 1
            return true
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if running < maxConcurrent {
                    running += 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append((token, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: token) }
        }
    }

    func release() {
        while let next = waiters.popLast() {
            next.continuation.resume(returning: true)
            return
        }
        running = max(0, running - 1)
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: idx)
            removed.continuation.resume(returning: false)
        }
    }
}

/// Async cached thumbnail loader using `NSCache` with in-flight deduplication,
/// shared `CGImage`/`NSImage` backing (zero double-decoding), LIFO bounded off-main-thread decoding,
/// scroll-ahead prefetching, and zero-overhead scroll reads.
@Observable
public final class ThumbnailImageLoader {
    private final class CachedImageBox: @unchecked Sendable {
        let cgImage: CGImage
        let nsImage: NSImage

        init(cgImage: CGImage) {
            self.cgImage = cgImage
            self.nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    private final class InFlightEntry {
        let task: Task<CachedImageBox?, Never>
        var activeWaiters: Set<UUID> = []

        init(task: Task<CachedImageBox?, Never>) {
            self.task = task
        }
    }

    @ObservationIgnored private let engine: any CharkleEngineProtocol
    @ObservationIgnored private let cache = NSCache<NSString, CachedImageBox>()
    @ObservationIgnored private let originalCache = NSCache<NSString, CachedImageBox>()
    @ObservationIgnored private var inFlight: [String: InFlightEntry] = [:]
    @ObservationIgnored private let scheduler = ThumbnailDecodeScheduler(maxConcurrent: 6)
    @ObservationIgnored private var prefetchTasks: [String: Task<Void, Never>] = [:]

    /// Increments ONLY on explicit invalidation / memory cache clear — never during normal image loads,
    /// so scrolling through thousands of cards triggers zero `@Observable` cascade invalidations.
    public private(set) var invalidationVersion: Int = 0

    public init(engine: any CharkleEngineProtocol, maxCount: Int = 1_500, maxCostBytes: Int = 320 * 1024 * 1024) {
        self.engine = engine
        cache.countLimit = maxCount
        cache.totalCostLimit = maxCostBytes
        originalCache.countLimit = 4
        originalCache.totalCostLimit = 180 * 1024 * 1024
    }

    private func cacheKey(assetID: UUID, tier: ThumbnailTier) -> String {
        "\(assetID.uuidString)-\(tier.rawValue)"
    }

    public func cachedImage(for assetID: UUID, tier: ThumbnailTier = .grid520) -> NSImage? {
        cache.object(forKey: cacheKey(assetID: assetID, tier: tier) as NSString)?.nsImage
    }

    public func cachedOriginalImage(for assetID: UUID) -> NSImage? {
        originalCache.object(forKey: assetID.uuidString as NSString)?.nsImage
    }

    /// Loads the true full-resolution original image off the main thread (applying EXIF orientation
    /// and staying safely within Metal's 16,384px texture dimension limit for extreme tall-strip screenshots).
    public func loadOriginalImage(for assetID: UUID, url: URL) async -> NSImage? {
        let key = assetID.uuidString as NSString
        if let hit = originalCache.object(forKey: key) {
            return hit.nsImage
        }
        guard !Task.isCancelled else { return nil }
        if let cg = await Self.decodeOriginalCGImage(from: url) {
            guard !Task.isCancelled else { return nil }
            let box = CachedImageBox(cgImage: cg)
            let cost = max(1, cg.width * cg.height * 4)
            originalCache.setObject(box, forKey: key, cost: cost)
            return box.nsImage
        }
        // Vector fallback (e.g. .svg originals where CGImageSource cannot rasterize directly)
        if url.pathExtension.lowercased() == "svg",
           let data = try? Data(contentsOf: url),
           let vectorImage = NSImage(data: data) {
            return vectorImage
        }
        return nil
    }

    /// Zero-bridging `CGImage` cache hit for direct `CALayer.contents` hardware compositing.
    public func cachedCGImage(for assetID: UUID, tier: ThumbnailTier = .grid520) -> CGImage? {
        cache.object(forKey: cacheKey(assetID: assetID, tier: tier) as NSString)?.cgImage
    }

    public func loadImage(for assetID: UUID, tier: ThumbnailTier = .grid520) async -> NSImage? {
        await loadBox(for: assetID, tier: tier)?.nsImage
    }

    public func loadCGImage(for assetID: UUID, tier: ThumbnailTier = .grid520) async -> CGImage? {
        await loadBox(for: assetID, tier: tier)?.cgImage
    }

    /// Resolves an already-cached local original file URL off the main thread without ever
    /// triggering cloud downloads — safe for 120Hz hover playback previews.
    public func resolveLocalCachedOriginalURL(for asset: AssetRecord) async -> URL? {
        let engine = self.engine
        return await Self.lookupCachedOriginal(engine: engine, asset: asset)
    }

    @concurrent
    private static func lookupCachedOriginal(engine: any CharkleEngineProtocol, asset: AssetRecord) async -> URL? {
        guard !Task.isCancelled else { return nil }
        return engine.cachedOriginalURL(for: asset)
    }

    /// Low-priority lookahead prefetching so upcoming cards during scrolling hit `cachedCGImage`
    /// synchronously with zero decode stall.
    public func prefetch(assetIDs: [UUID], tier: ThumbnailTier = .grid520) {
        let wantedKeys = Set(assetIDs.map { cacheKey(assetID: $0, tier: tier) })
        // Cancel stale prefetch tasks no longer in the lookahead window
        for (key, task) in prefetchTasks where !wantedKeys.contains(key) {
            task.cancel()
            prefetchTasks.removeValue(forKey: key)
        }
        for assetID in assetIDs {
            let key = cacheKey(assetID: assetID, tier: tier)
            if cache.object(forKey: key as NSString) != nil || prefetchTasks[key] != nil || inFlight[key] != nil {
                continue
            }
            let task = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = await self.loadBox(for: assetID, tier: tier)
                self.prefetchTasks.removeValue(forKey: key)
            }
            prefetchTasks[key] = task
        }
    }

    private func loadBox(for assetID: UUID, tier: ThumbnailTier) async -> CachedImageBox? {
        let key = cacheKey(assetID: assetID, tier: tier)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }
        guard !Task.isCancelled else { return nil }

        let entry: InFlightEntry
        if let existing = inFlight[key] {
            entry = existing
        } else {
            let engine = self.engine
            let scheduler = self.scheduler
            let maxPixel = tier == .grid520 ? 720 : 1400
            let task = Task<CachedImageBox?, Never> {
                guard await scheduler.acquire() else { return nil }
                defer { Task { await scheduler.release() } }
                guard !Task.isCancelled else { return nil }

                let url: URL?
                if let direct = engine.cachedThumbnailURL(for: assetID, tier: tier) {
                    url = direct
                } else {
                    url = await engine.thumbnailURL(for: assetID, tier: tier)
                }
                guard let url, !Task.isCancelled else { return nil }
                guard let cg = await Self.decodeCGImage(from: url, maxPixelSize: maxPixel) else { return nil }
                return CachedImageBox(cgImage: cg)
            }
            entry = InFlightEntry(task: task)
            inFlight[key] = entry
        }

        let waiterToken = UUID()
        entry.activeWaiters.insert(waiterToken)
        let box: CachedImageBox? = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self, weak entry] in
                guard let self, let entry else { return }
                self.releaseWaiter(token: waiterToken, entry: entry, forKey: key)
            }
        }
        releaseWaiter(token: waiterToken, entry: entry, forKey: key)

        if let box {
            let cost = box.cgImage.width * box.cgImage.height * 4
            cache.setObject(box, forKey: key as NSString, cost: max(cost, 1))
        }
        return box
    }

    private func releaseWaiter(token: UUID, entry: InFlightEntry, forKey key: String) {
        guard entry.activeWaiters.remove(token) != nil else { return }
        if entry.activeWaiters.isEmpty {
            if inFlight[key] === entry {
                inFlight.removeValue(forKey: key)
            }
            entry.task.cancel()
        }
    }

    public func invalidate(assetID: UUID) {
        originalCache.removeObject(forKey: assetID.uuidString as NSString)
        for tier in [ThumbnailTier.grid520, .preview1400] {
            let key = cacheKey(assetID: assetID, tier: tier)
            cache.removeObject(forKey: key as NSString)
            inFlight[key]?.task.cancel()
            inFlight.removeValue(forKey: key)
            prefetchTasks[key]?.cancel()
            prefetchTasks.removeValue(forKey: key)
        }
        invalidationVersion &+= 1
    }

    public func clearMemoryCache() {
        cache.removeAllObjects()
        originalCache.removeAllObjects()
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        invalidationVersion &+= 1
    }

    @concurrent
    private static func decodeCGImage(from url: URL, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @concurrent
    private static func decodeOriginalCGImage(from url: URL) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelW = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelH = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        // Apple Silicon Metal max single texture edge is 16,384px; cap total decoded area at ~64MP (~256MB RGBA)
        // so normal high-res art and long vertical strips decode at true 100% original resolution without GPU drops.
        let maxTextureSide = 16_000
        let maxPixelArea: Double = 64_000_000.0

        var targetMaxSide = max(pixelW, pixelH)
        if targetMaxSide <= 0 {
            targetMaxSide = 4_096
        }
        if pixelW > 0 && pixelH > 0 {
            let area = Double(pixelW) * Double(pixelH)
            if area > maxPixelArea {
                let scale = sqrt(maxPixelArea / area)
                targetMaxSide = max(1_400, Int((Double(max(pixelW, pixelH)) * scale).rounded(.down)))
            }
        }
        targetMaxSide = min(targetMaxSide, maxTextureSide)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxSide,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
    public let contentMode: ContentMode
    public let enableHoverPlayback: Bool

    @State private var loadedImage: NSImage?
    @State private var loadedAssetID: UUID?
    @State private var isPointerHovering: Bool = false

    public init(
        asset: AssetRecord,
        loader: ThumbnailImageLoader,
        tier: ThumbnailTier = .grid520,
        cornerRadius: CGFloat = 12,
        isHovered: Bool = false,
        crop: NormalizedCropRect? = nil,
        contentMode: ContentMode = .fill,
        enableHoverPlayback: Bool = true
    ) {
        self.asset = asset
        self.loader = loader
        self.tier = tier
        self.cornerRadius = cornerRadius
        self.isHovered = isHovered
        self.crop = crop
        self.contentMode = contentMode
        self.enableHoverPlayback = enableHoverPlayback
    }

    private var shouldPlayHoverPreview: Bool {
        enableHoverPlayback
            && crop == nil
            && HoverMediaPreviewLayerController.supportsHoverPlayback(asset)
            && (isHovered || isPointerHovering)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let activeLoaded = (loadedAssetID == asset.id) ? loadedImage : nil
        let displayImage = activeLoaded
            ?? loader.cachedImage(for: asset.id, tier: tier)
            ?? (tier != .grid520 ? loader.cachedImage(for: asset.id, tier: .grid520) : nil)
        let canHoverPlay = enableHoverPlayback && crop == nil && HoverMediaPreviewLayerController.supportsHoverPlayback(asset)
        Color.clear
            .overlay {
                if let image = displayImage {
                    croppedImageView(image)
                } else {
                    ProceduralMediaFallbackCard(asset: asset, isHovered: isHovered || isPointerHovering)
                }
            }
            .overlay {
                if shouldPlayHoverPreview {
                    HoverMediaPreviewOverlay(
                        asset: asset,
                        loader: loader,
                        cornerRadius: cornerRadius,
                        fillMode: contentMode == .fill
                    )
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .clipShape(shape)
            .contentShape(shape)
            .onHover { hovering in
                guard canHoverPlay else { return }
                if isPointerHovering != hovering {
                    isPointerHovering = hovering
                }
            }
            .onDisappear {
                if isPointerHovering {
                    isPointerHovering = false
                }
            }
            .task(id: "\(asset.id.uuidString)-\(tier.rawValue)-\(loader.invalidationVersion)") {
                let targetID = asset.id
                if let cached = loader.cachedImage(for: targetID, tier: tier) {
                    if loadedAssetID != targetID || loadedImage !== cached {
                        loadedAssetID = targetID
                        loadedImage = cached
                    }
                    return
                }
                let img = await loader.loadImage(for: targetID, tier: tier)
                if !Task.isCancelled {
                    loadedAssetID = targetID
                    loadedImage = img
                }
            }
    }

    @ViewBuilder
    private func croppedImageView(_ image: NSImage) -> some View {
        let quality: Image.Interpolation = tier == .grid520 ? .medium : .high
        if let crop, crop != .full, crop.width > 0.04, crop.height > 0.04,
           let croppedNS = Self.cropImage(image, normalized: crop) {
            Image(nsImage: croppedNS)
                .resizable()
                .interpolation(quality)
                .aspectRatio(contentMode: contentMode == .fit ? .fit : .fill)
        } else if contentMode == .fit {
            Image(nsImage: image)
                .resizable()
                .interpolation(quality)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(quality)
                .aspectRatio(contentMode: .fill)
        }
    }

    private static func cropImage(_ image: NSImage, normalized crop: NormalizedCropRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let clamped = crop.clamped()
        let pixelRect = CGRect(
            x: (clamped.x * Double(cg.width)).rounded(.down),
            y: (clamped.y * Double(cg.height)).rounded(.down),
            width: max(4, (clamped.width * Double(cg.width)).rounded()),
            height: max(4, (clamped.height * Double(cg.height)).rounded())
        ).intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard pixelRect.width >= 4, pixelRect.height >= 4, let cropped = cg.cropping(to: pixelRect) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
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
                case .model3D:
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
            // Lightweight radial highlight (avoids per-card offscreen Gaussian blur during fast scroll)
            RadialGradient(
                colors: [Color.white.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 4,
                endRadius: 160
            )
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

import CharkleCore
import Foundation
import ImageIO
import UIKit

/// Cooperative cancellation-aware concurrency limiter so bursts of off-main-thread ImageIO decodes
/// during fast 120Hz scrolling never saturate CPU cores or starve visible tiles/preview loads.
/// Uses LIFO / high-priority wakeup so freshly visible cards jump ahead of scrolled-past backlog.
private actor ThumbnailDecodeGate {
    private struct Waiter {
        let id: UUID
        let highPriority: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active: Int = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(highPriority: Bool = false) async -> Bool {
        if Task.isCancelled { return false }
        if active < limit {
            active += 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if active < limit {
                    active += 1
                    continuation.resume(returning: true)
                    return
                }
                waiters.append(Waiter(id: waiterID, highPriority: highPriority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume(returning: false)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let nextIndex: Int
            if let highIdx = waiters.lastIndex(where: { $0.highPriority }) {
                nextIndex = highIdx
            } else {
                nextIndex = waiters.count - 1
            }
            let next = waiters.remove(at: nextIndex)
            next.continuation.resume(returning: true)
        } else {
            active = max(0, active - 1)
        }
    }
}

/// Memory-bounded, off-main-thread decoded image loader for Charkle thumbnails & previews:
/// - Moves both local cache path checks (`cachedThumbnailURL` / `cachedOriginalURL`) and
///   ImageIO downsampling + `preparingForDisplay()` off the MainActor inside `autoreleasepool`.
/// - Separates grid (`grid520`) and high-priority preview (`preview1400` / original) decode gates
///   with cancellation propagation + LIFO visible priority so fast scrolling never stalls behind
///   off-screen backlog.
/// - Stamps per-asset invalidation generations so in-flight decodes never re-poison updated covers.
/// - Adapts original decode bounds for tall long-strip images and purges caches on iOS memory warning.
@Observable
@MainActor
final class MobileThumbnailCache {
    private final class InFlightDecode {
        let id = UUID()
        let task: Task<UIImage?, Never>
        var waiterTokens: Set<UUID> = []

        init(task: Task<UIImage?, Never>) {
            self.task = task
        }
    }

    private let engine: any CharkleEngineProtocol

    @ObservationIgnored
    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 640
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    @ObservationIgnored
    private let originalCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    @ObservationIgnored
    private let gridDecodeGate = ThumbnailDecodeGate(limit: 4)

    @ObservationIgnored
    private let previewDecodeGate = ThumbnailDecodeGate(limit: 2)

    @ObservationIgnored
    private var inFlight: [String: InFlightDecode] = [:]

    @ObservationIgnored
    private var inFlightOriginals: [UUID: InFlightDecode] = [:]

    @ObservationIgnored
    private var prefetchTasksByTier: [ThumbnailTier: [UUID: Task<Void, Never>]] = [:]

    @ObservationIgnored
    private var globalGeneration: UInt64 = 0

    @ObservationIgnored
    private var assetGenerations: [UUID: UInt64] = [:]

    @ObservationIgnored
    private nonisolated(unsafe) var memoryWarningObserver: NSObjectProtocol?

    /// Incremented whenever background sync or cover-frame updates land new thumbnails.
    var revision: Int = 0

    init(engine: any CharkleEngineProtocol) {
        self.engine = engine
        self.memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMemoryWarning()
            }
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func handleMemoryWarning() {
        cancelAllPrefetches()
        originalCache.removeAllObjects()
        memoryCache.removeAllObjects()
    }

    func cachedImage(for assetID: UUID, tier: ThumbnailTier) -> UIImage? {
        memoryCache.object(forKey: cacheKey(assetID: assetID, tier: tier))
    }

    func cachedOriginalImage(for assetID: UUID) -> UIImage? {
        originalCache.object(forKey: assetID.uuidString as NSString)
    }

    /// Instant synchronous Frame-0 lookup for Quick Look stages:
    /// prefers cached original -> `preview1400` -> `grid520` so swiped pages never flash a spinner.
    func bestCachedPreviewImage(for assetID: UUID) -> UIImage? {
        cachedOriginalImage(for: assetID)
            ?? cachedImage(for: assetID, tier: .preview1400)
            ?? cachedImage(for: assetID, tier: .grid520)
    }

    func invalidate(assetIDs: [UUID]) {
        if assetIDs.isEmpty {
            globalGeneration &+= 1
            cancelAllPrefetches()
            for entry in inFlight.values {
                entry.task.cancel()
            }
            inFlight.removeAll()
            for entry in inFlightOriginals.values {
                entry.task.cancel()
            }
            inFlightOriginals.removeAll()
            memoryCache.removeAllObjects()
            originalCache.removeAllObjects()
        } else {
            for id in assetIDs {
                assetGenerations[id, default: 0] &+= 1
                for tier in [ThumbnailTier.grid520, .preview1400] {
                    let key = cacheKey(assetID: id, tier: tier)
                    let keyString = key as String
                    if let entry = inFlight.removeValue(forKey: keyString) {
                        entry.task.cancel()
                    }
                    if let prefetch = prefetchTasksByTier[tier]?.removeValue(forKey: id) {
                        prefetch.cancel()
                    }
                    memoryCache.removeObject(forKey: key)
                }
                if let origEntry = inFlightOriginals.removeValue(forKey: id) {
                    origEntry.task.cancel()
                }
                originalCache.removeObject(forKey: id.uuidString as NSString)
            }
        }
        revision &+= 1
    }

    /// Opportunistically warms RAM cache for upcoming gallery cards or adjacent preview pages
    /// off the main thread, cancelling stale prefetches from previous scroll buckets immediately.
    func prefetch(assetIDs: [UUID], tier: ThumbnailTier) {
        let keepSet = Set(assetIDs)
        if var existing = prefetchTasksByTier[tier] {
            for (id, task) in existing where !keepSet.contains(id) {
                task.cancel()
                existing.removeValue(forKey: id)
            }
            prefetchTasksByTier[tier] = existing
        }

        for id in assetIDs {
            let key = cacheKey(assetID: id, tier: tier)
            if memoryCache.object(forKey: key) != nil { continue }
            if inFlight[key as String] != nil { continue }
            if prefetchTasksByTier[tier]?[id] != nil { continue }

            let prefetchTask = Task(priority: tier == .preview1400 ? .userInitiated : .utility) { [weak self] in
                guard let self else { return }
                _ = await self.loadImage(for: id, tier: tier, highPriority: tier == .preview1400)
                if !Task.isCancelled {
                    self.prefetchTasksByTier[tier]?.removeValue(forKey: id)
                }
            }
            prefetchTasksByTier[tier, default: [:]][id] = prefetchTask
        }
    }

    private func cancelAllPrefetches() {
        for map in prefetchTasksByTier.values {
            for task in map.values {
                task.cancel()
            }
        }
        prefetchTasksByTier.removeAll()
    }

    func loadImage(for assetID: UUID, tier: ThumbnailTier, highPriority: Bool = true) async -> UIImage? {
        let key = cacheKey(assetID: assetID, tier: tier)
        if let hit = memoryCache.object(forKey: key) {
            return hit
        }
        guard !Task.isCancelled else { return nil }

        let keyString = key as String
        let expectedGlobal = globalGeneration
        let expectedAsset = assetGenerations[assetID] ?? 0
        let callerToken = UUID()

        let entry: InFlightDecode
        if let existing = inFlight[keyString] {
            entry = existing
        } else {
            let maxPixelSize = tier == .grid520 ? 640 : 1_600
            let engine = self.engine
            let gate = tier == .grid520 ? gridDecodeGate : previewDecodeGate
            let task = Task<UIImage?, Never> {
                await Self.resolveAndDecodeThumbnail(
                    engine: engine,
                    assetID: assetID,
                    tier: tier,
                    maxPixelSize: maxPixelSize,
                    highPriority: highPriority,
                    gate: gate
                )
            }
            let created = InFlightDecode(task: task)
            inFlight[keyString] = created
            entry = created
        }

        entry.waiterTokens.insert(callerToken)
        let entryID = entry.id

        let image = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseInFlightThumbnailWaiter(key: keyString, entryID: entryID, token: callerToken)
            }
        }

        entry.waiterTokens.remove(callerToken)
        if inFlight[keyString]?.id == entryID {
            inFlight[keyString] = nil
        }

        if let image,
           globalGeneration == expectedGlobal,
           (assetGenerations[assetID] ?? 0) == expectedAsset {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memoryCache.setObject(image, forKey: key, cost: max(1, cost))
            return image
        }
        return nil
    }

    func loadOriginalImage(for asset: AssetRecord) async -> UIImage? {
        let cacheID = asset.id.uuidString as NSString
        if let hit = originalCache.object(forKey: cacheID) {
            return hit
        }
        guard !Task.isCancelled else { return nil }

        let expectedGlobal = globalGeneration
        let expectedAsset = assetGenerations[asset.id] ?? 0
        let callerToken = UUID()

        let entry: InFlightDecode
        if let existing = inFlightOriginals[asset.id] {
            entry = existing
        } else {
            let engine = self.engine
            let gate = previewDecodeGate
            let maxPixelSize = Self.recommendedOriginalMaxPixelSize(for: asset)
            let task = Task<UIImage?, Never> {
                await Self.resolveAndDecodeOriginal(
                    engine: engine,
                    asset: asset,
                    maxPixelSize: maxPixelSize,
                    gate: gate
                )
            }
            let created = InFlightDecode(task: task)
            inFlightOriginals[asset.id] = created
            entry = created
        }

        entry.waiterTokens.insert(callerToken)
        let entryID = entry.id

        let decoded = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseInFlightOriginalWaiter(assetID: asset.id, entryID: entryID, token: callerToken)
            }
        }

        entry.waiterTokens.remove(callerToken)
        if inFlightOriginals[asset.id]?.id == entryID {
            inFlightOriginals[asset.id] = nil
        }

        if let decoded,
           globalGeneration == expectedGlobal,
           (assetGenerations[asset.id] ?? 0) == expectedAsset {
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            originalCache.setObject(decoded, forKey: cacheID, cost: max(1, cost))
            return decoded
        }
        guard !Task.isCancelled else { return nil }
        return await loadImage(for: asset.id, tier: .preview1400, highPriority: true)
    }

    private func releaseInFlightThumbnailWaiter(key: String, entryID: UUID, token: UUID) {
        guard let entry = inFlight[key], entry.id == entryID else { return }
        entry.waiterTokens.remove(token)
        if entry.waiterTokens.isEmpty {
            entry.task.cancel()
            inFlight[key] = nil
        }
    }

    private func releaseInFlightOriginalWaiter(assetID: UUID, entryID: UUID, token: UUID) {
        guard let entry = inFlightOriginals[assetID], entry.id == entryID else { return }
        entry.waiterTokens.remove(token)
        if entry.waiterTokens.isEmpty {
            entry.task.cancel()
            inFlightOriginals[assetID] = nil
        }
    }

    private func cacheKey(assetID: UUID, tier: ThumbnailTier) -> NSString {
        "\(assetID.uuidString):\(tier.rawValue)" as NSString
    }

    /// Preserves crisp readable width (~1400px) on tall long-strip UI screenshots & panoramas
    /// while bounding total decoded area to ~16 MP (~64 MB RGBA) for safe iOS RAM usage.
    private nonisolated static func recommendedOriginalMaxPixelSize(for asset: AssetRecord) -> Int {
        let w = Double(asset.pixelWidth)
        let h = Double(asset.pixelHeight)
        guard w > 0, h > 0 else { return 2_600 }
        let longSide = max(w, h)
        let shortSide = min(w, h)
        let ratio = longSide / max(1, shortSide)
        if ratio >= 2.0 {
            let desiredShort = min(shortSide, 1_400.0)
            let desiredLong = desiredShort * ratio
            // Cap total pixel area at 16_000_000 px so extreme 1:20 strips stay memory-safe
            let areaCappedLong = sqrt(16_000_000.0 * ratio)
            let target = min(longSide, min(8_192.0, min(desiredLong, areaCappedLong)))
            return max(2_600, Int(target.rounded(.up)))
        }
        return 2_600
    }

    @concurrent
    private static func resolveAndDecodeThumbnail(
        engine: any CharkleEngineProtocol,
        assetID: UUID,
        tier: ThumbnailTier,
        maxPixelSize: Int,
        highPriority: Bool,
        gate: ThumbnailDecodeGate
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard await gate.acquire(highPriority: highPriority) else { return nil }
        var holding = true

        guard !Task.isCancelled else {
            await gate.release()
            return nil
        }

        let localURL: URL?
        if let fastURL = engine.cachedThumbnailURL(for: assetID, tier: tier) {
            localURL = fastURL
        } else {
            holding = false
            await gate.release()
            let fetched = await engine.thumbnailURL(for: assetID, tier: tier)
            guard let fetched, !Task.isCancelled else { return nil }
            guard await gate.acquire(highPriority: highPriority) else { return nil }
            holding = true
            guard !Task.isCancelled else {
                await gate.release()
                return nil
            }
            localURL = fetched
        }

        let decoded: UIImage?
        if let localURL, !Task.isCancelled {
            decoded = decodeDownsampledSync(at: localURL, maxPixelSize: maxPixelSize)
        } else {
            decoded = nil
        }

        if holding {
            await gate.release()
        }
        return decoded
    }

    @concurrent
    private static func resolveAndDecodeOriginal(
        engine: any CharkleEngineProtocol,
        asset: AssetRecord,
        maxPixelSize: Int,
        gate: ThumbnailDecodeGate
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let localURL: URL?
        if let cached = engine.cachedOriginalURL(for: asset) {
            localURL = cached
        } else {
            localURL = try? await engine.originalURL(for: asset.id)
        }
        guard let localURL, !Task.isCancelled else { return nil }

        guard await gate.acquire(highPriority: true) else { return nil }
        guard !Task.isCancelled else {
            await gate.release()
            return nil
        }
        let decoded = decodeDownsampledSync(at: localURL, maxPixelSize: maxPixelSize)
        await gate.release()
        return decoded
    }

    private nonisolated static func decodeDownsampledSync(at url: URL, maxPixelSize: Int) -> UIImage? {
        autoreleasepool {
            guard !Task.isCancelled else { return nil }
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
                return nil
            }
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                let raw = UIImage(cgImage: cgImage)
                return raw.preparingForDisplay() ?? raw
            }
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let raw = UIImage(cgImage: cgImage)
                return raw.preparingForDisplay() ?? raw
            }
            return nil
        }
    }
}

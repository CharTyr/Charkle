import CharkleCore
import Foundation
import ImageIO
import UIKit

/// Memory-bounded, background-decoded image loader for two-tier Charkle thumbnails
/// (`grid520` for waterfall grids, `preview1400` for Quick Look).
@Observable
final class MobileThumbnailCache {
    private let engine: any CharkleEngineProtocol
    @ObservationIgnored
    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 450
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    @ObservationIgnored
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Incremented whenever background sync lands new thumbnails so visible tiles re-check smoothly.
    var revision: Int = 0

    init(engine: any CharkleEngineProtocol) {
        self.engine = engine
    }

    func cachedImage(for assetID: UUID, tier: ThumbnailTier) -> UIImage? {
        memoryCache.object(forKey: cacheKey(assetID: assetID, tier: tier))
    }

    func invalidate(assetIDs: [UUID]) {
        if assetIDs.isEmpty {
            memoryCache.removeAllObjects()
        } else {
            for id in assetIDs {
                memoryCache.removeObject(forKey: cacheKey(assetID: id, tier: .grid520))
                memoryCache.removeObject(forKey: cacheKey(assetID: id, tier: .preview1400))
            }
        }
        revision &+= 1
    }

    func loadImage(for assetID: UUID, tier: ThumbnailTier) async -> UIImage? {
        let key = cacheKey(assetID: assetID, tier: tier)
        if let hit = memoryCache.object(forKey: key) {
            return hit
        }
        let keyString = key as String
        if let existing = inFlight[keyString] {
            return await existing.value
        }

        let maxPixelSize = tier == .grid520 ? 720 : 1_600
        let engine = self.engine
        let task = Task<UIImage?, Never> {
            let localURL: URL?
            if let fastURL = engine.cachedThumbnailURL(for: assetID, tier: tier) {
                localURL = fastURL
            } else {
                localURL = await engine.thumbnailURL(for: assetID, tier: tier)
            }
            guard let localURL, !Task.isCancelled else { return nil }
            return await Self.decodeDownsampledImage(at: localURL, maxPixelSize: maxPixelSize)
        }
        inFlight[keyString] = task
        let image = await task.value
        inFlight[keyString] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memoryCache.setObject(image, forKey: key, cost: max(1, cost))
        }
        return image
    }

    func loadOriginalImage(for asset: AssetRecord) async -> UIImage? {
        if let cached = engine.cachedOriginalURL(for: asset),
           let image = await Self.decodeDownsampledImage(at: cached, maxPixelSize: 2_800) {
            return image
        }
        if let downloaded = try? await engine.originalURL(for: asset.id),
           let image = await Self.decodeDownsampledImage(at: downloaded, maxPixelSize: 2_800) {
            return image
        }
        return await loadImage(for: asset.id, tier: .preview1400)
    }

    private func cacheKey(assetID: UUID, tier: ThumbnailTier) -> NSString {
        "\(assetID.uuidString):\(tier.rawValue)" as NSString
    }

    @concurrent
    private nonisolated static func decodeDownsampledImage(at url: URL, maxPixelSize: Int) async -> UIImage? {
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
            return UIImage(cgImage: cgImage)
        }
        if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return UIImage(cgImage: cgImage)
        }
        return nil
    }
}

#if canImport(AppKit)
import AppKit
public typealias PinterestPlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PinterestPlatformImage = UIImage
#endif
import CoreGraphics
import Foundation
import ImageIO

/// High-throughput pooled remote image loader & bounded memory cache for Pinterest `i.pinimg.com` tiles.
///
/// Decodes images off the main thread into `Sendable` `CGImage`s while exposing instant synchronous
/// `@MainActor` cache lookups so 120Hz infinite 2D panning never flickers when revisiting cached cards.
@MainActor
public final class PinterestImageCache {
    public static let shared = PinterestImageCache()

    private let cache: NSCache<NSURL, PinterestPlatformImage> = {
        let c = NSCache<NSURL, PinterestPlatformImage>()
        #if os(iOS)
        c.countLimit = 460
        c.totalCostLimit = 120 * 1024 * 1024
        #else
        c.countLimit = 720
        c.totalCostLimit = 220 * 1024 * 1024
        #endif
        return c
    }()

    private var inFlight: [URL: Task<CGImage?, Never>] = [:]
    private var prefetchQueue: [(url: URL, maxPixelSize: Int)] = []
    private var activePrefetchCount: Int = 0
    private let maxConcurrentPrefetches: Int = 6
    #if os(iOS)
    private var memoryWarningObserver: (any NSObjectProtocol)?
    #endif

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 12
        config.timeoutIntervalForRequest = 14
        config.timeoutIntervalForResource = 25
        config.urlCache = URLCache(
            memoryCapacity: 36 * 1024 * 1024,
            diskCapacity: 240 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private init() {
        #if os(iOS)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearMemoryCache()
            }
        }
        #endif
    }

    /// Instant synchronous memory-cache hit on `@MainActor` for zero-flicker viewport recycling.
    public func cachedImage(for url: URL) -> PinterestPlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    public func image(for url: URL, maxPixelSize: Int = 960) async -> PinterestPlatformImage? {
        if let hit = cache.object(forKey: url as NSURL) {
            return hit
        }

        let decodeTask: Task<CGImage?, Never>
        let ownsTask: Bool
        if let existing = inFlight[url] {
            decodeTask = existing
            ownsTask = false
        } else {
            let targetPixels = max(200, maxPixelSize)
            let created = Task.detached(priority: .userInitiated) { () -> CGImage? in
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 14)
                request.setValue("https://www.pinterest.com/", forHTTPHeaderField: "Referer")
                request.setValue("image/webp,image/avif,image/png,image/jpeg,*/*", forHTTPHeaderField: "Accept")
                guard let (data, response) = try? await PinterestImageCache.session.data(for: request),
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty else {
                    return nil
                }
                return PinterestImageCache.decodeCGImage(from: data, maxPixelSize: targetPixels)
            }
            inFlight[url] = created
            decodeTask = created
            ownsTask = true
        }

        let cgImage = await decodeTask.value
        if ownsTask {
            inFlight.removeValue(forKey: url)
        }
        guard let cgImage else { return nil }

        if let hit = cache.object(forKey: url as NSURL) {
            return hit
        }
        let platformImage = Self.makePlatformImage(from: cgImage)
        let cost = max(1024, cgImage.bytesPerRow * cgImage.height)
        cache.setObject(platformImage, forKey: url as NSURL, cost: cost)
        return platformImage
    }

    public func prefetch(_ urls: [URL], maxPixelSize: Int = 640) {
        prefetchPrioritized(urls, maxPixelSize: maxPixelSize, replacePending: false)
    }

    /// Prioritized predictive prefetch queue for infinite spatial panning.
    /// When `replacePending` is `true`, replaces queued-but-not-yet-started URLs with the freshest
    /// directional lookahead predictions so rapid pan direction reversals never waste bandwidth
    /// on cards the user is moving away from.
    public func prefetchPrioritized(
        _ urls: [URL],
        maxPixelSize: Int = 640,
        replacePending: Bool = true
    ) {
        let capped = Array(urls.prefix(32))
        var filtered: [(url: URL, maxPixelSize: Int)] = []
        filtered.reserveCapacity(capped.count)
        var seen = Set<URL>()
        for url in capped {
            guard seen.insert(url).inserted else { continue }
            if cache.object(forKey: url as NSURL) != nil || inFlight[url] != nil { continue }
            filtered.append((url, maxPixelSize))
        }
        if replacePending {
            prefetchQueue = filtered
        } else {
            let existing = Set(prefetchQueue.map(\.url))
            prefetchQueue.append(contentsOf: filtered.filter { !existing.contains($0.url) })
        }
        drainPrefetchQueue()
    }

    private func drainPrefetchQueue() {
        while activePrefetchCount < maxConcurrentPrefetches, !prefetchQueue.isEmpty {
            let next = prefetchQueue.removeFirst()
            if cache.object(forKey: next.url as NSURL) != nil || inFlight[next.url] != nil {
                continue
            }
            activePrefetchCount += 1
            Task(priority: .utility) { @MainActor [weak self] in
                _ = await self?.image(for: next.url, maxPixelSize: next.maxPixelSize)
                guard let self else { return }
                self.activePrefetchCount = max(0, self.activePrefetchCount - 1)
                self.drainPrefetchQueue()
            }
        }
    }

    public func clearMemoryCache() {
        cache.removeAllObjects()
        prefetchQueue.removeAll(keepingCapacity: false)
    }

    private static func makePlatformImage(from cgImage: CGImage) -> PinterestPlatformImage {
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #elseif canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #endif
    }

    private nonisolated static func decodeCGImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(200, maxPixelSize)
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }
}

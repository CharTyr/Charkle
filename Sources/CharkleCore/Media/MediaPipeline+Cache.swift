import Foundation

extension MediaPipeline {
    func cache(in database: LibraryDatabase, evict: Bool, keeping: Set<UUID>) async throws -> CacheStats {
        try await database.transaction { [self] store in
            try store.removeDeletedMedia(using: self)
            let originalBudget = CacheStats().budgetBytes
            let budget: Int64 = try store.state("cacheBudgetBytes") ?? originalBudget
            let pinned = try store.protectedAssetIDs()
            let files = originalEntries()
            var size = files.reduce(Int64(0)) { $0 + $1.bytes }
            var count = files.count
            if evict && size > budget {
                let recoverable = Set(try store.assetDriveBindings().map { $0.1 })
                let access = try store.originalAccessTimes()
                let candidates = files.filter { !pinned.contains($0.id) && !keeping.contains($0.id) && recoverable.contains($0.id) }
                    .sorted { (access[$0.id] ?? .distantPast, $0.id.uuidString) < (access[$1.id] ?? .distantPast, $1.id.uuidString) }
                for entry in candidates where size > budget {
                    try FileManager.default.removeItem(at: entry.url)
                    size -= entry.bytes
                    count -= 1
                    if var asset = try store.asset(id: entry.id) {
                        asset.isLocalOriginalCached = false
                        try store.put(asset)
                    }
                }
            }
            let pinnedFiles = files.filter { pinned.contains($0.id) }
            return CacheStats(thumbnailBytes: thumbnailBytes(), originalCacheBytes: size,
                              pinnedOfflineBytes: pinnedFiles.reduce(0) { $0 + $1.bytes }, budgetBytes: budget,
                              cachedOriginalCount: count, pinnedAssetCount: pinned.count)
        }
    }
}

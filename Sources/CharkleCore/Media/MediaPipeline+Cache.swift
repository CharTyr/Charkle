import Foundation

extension MediaPipeline {
    private struct EvictionPlan: Sendable {
        let candidatesToRemove: [(id: UUID, url: URL, bytes: Int64)]
        let budget: Int64
        let initialSize: Int64
        let initialCount: Int
        let pinnedOfflineBytes: Int64
        let pinnedAssetCount: Int
    }

    func cache(
        in database: LibraryDatabase,
        evict: Bool,
        keeping: Set<UUID>,
        canEvictCloudOriginals: Bool = true
    ) async throws -> CacheStats {
        try await database.removeDeletedMedia(using: self)
        // Enumerate Originals/ outside SQLite write lock so filesystem I/O never holds BEGIN IMMEDIATE.
        let files = originalEntries()
        let totalSize = files.reduce(Int64(0)) { $0 + $1.bytes }

        let plan = try await database.transaction { store -> EvictionPlan in
            let originalBudget = CacheStats().budgetBytes
            let budget: Int64 = try store.state("cacheBudgetBytes") ?? originalBudget
            let syncCfg: DriveSyncConfig? = try store.state("driveConfig")
            let pinned = try store.protectedAssetIDs()
            let pinnedFiles = files.filter { pinned.contains($0.id) }
            let pinnedBytes = pinnedFiles.reduce(Int64(0)) { $0 + $1.bytes }

            // Never evict local originals in pure local mode or when cloud recovery is unavailable.
            let hasCloudBackend = syncCfg.map { !$0.enabledCloudBackends.isEmpty } ?? false
            let evictionAllowed = evict && canEvictCloudOriginals && hasCloudBackend && totalSize > budget
            var toRemove: [(id: UUID, url: URL, bytes: Int64)] = []
            if evictionAllowed {
                let recoverable = Set(try store.assetDriveBindings().map { $0.1 })
                let access = try store.originalAccessTimes()
                let candidates = files.filter { !pinned.contains($0.id) && !keeping.contains($0.id) && recoverable.contains($0.id) }
                    .sorted { (access[$0.id] ?? .distantPast, $0.id.uuidString) < (access[$1.id] ?? .distantPast, $1.id.uuidString) }
                var projectedSize = totalSize
                for entry in candidates where projectedSize > budget {
                    toRemove.append(entry)
                    projectedSize -= entry.bytes
                }
            }

            return EvictionPlan(
                candidatesToRemove: toRemove,
                budget: budget,
                initialSize: totalSize,
                initialCount: files.count,
                pinnedOfflineBytes: pinnedBytes,
                pinnedAssetCount: pinned.count
            )
        }

        if plan.candidatesToRemove.isEmpty {
            return CacheStats(
                thumbnailBytes: thumbnailBytes(),
                originalCacheBytes: plan.initialSize,
                pinnedOfflineBytes: plan.pinnedOfflineBytes,
                budgetBytes: plan.budget,
                cachedOriginalCount: plan.initialCount,
                pinnedAssetCount: plan.pinnedAssetCount
            )
        }

        // Unlink files outside the SQLite transaction so a DB rollback can never leave
        // unlinked files marked cached, and missing files never abort eviction.
        var removedIDs: [UUID] = []
        var removedBytes: Int64 = 0
        for entry in plan.candidatesToRemove {
            do {
                try FileManager.default.removeItem(at: entry.url)
                removedIDs.append(entry.id)
                removedBytes += entry.bytes
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                removedIDs.append(entry.id)
                removedBytes += entry.bytes
            } catch {
                continue
            }
        }

        let finalizedIDs = removedIDs
        if !finalizedIDs.isEmpty {
            invalidateOriginalIndex()
            try await database.transaction { store in
                for id in finalizedIDs {
                    if var asset = try store.asset(id: id) {
                        asset.isLocalOriginalCached = false
                        try store.put(asset)
                    }
                }
                try store.removeOriginalCacheEntries(finalizedIDs)
            }
        }

        return CacheStats(
            thumbnailBytes: thumbnailBytes(),
            originalCacheBytes: max(0, plan.initialSize - removedBytes),
            pinnedOfflineBytes: plan.pinnedOfflineBytes,
            budgetBytes: plan.budget,
            cachedOriginalCount: max(0, plan.initialCount - finalizedIDs.count),
            pinnedAssetCount: plan.pinnedAssetCount
        )
    }
}

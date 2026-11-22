import CharkleCanvas
import CharkleCore
import Foundation
import os

private let libraryStoreLogger = Logger(subsystem: "com.charkle.app", category: "LibraryStore")

/// Domain store for the visual reference library, inbox triage, folders, tags, filtering,
/// multi-selection, batch editing, and asset ingestion.
@Observable
public final class LibraryStore {
    public let engine: any CharkleEngineProtocol
    public let thumbnailLoader: ThumbnailImageLoader

    public var assets: [AssetRecord] = []
    public var allAssetsByID: [UUID: AssetRecord] = [:]
    public var folders: [FolderRecord] = []
    public var tagCounts: [TagCount] = []
    public var inboxCount: Int = 0

    public var filter: FilterCriteria = FilterCriteria()
    public var selectedAssetIDs: Set<UUID> = []

    public var similarAssets: [ScoredAsset] = []
    public var suggestedFolder: FolderSuggestion?

    public var isLoading: Bool = false
    public var lastError: String?

    private var inspectorContextTask: Task<Void, Never>?

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine
        self.thumbnailLoader = ThumbnailImageLoader(engine: engine)
    }

    public var primarySelectedAsset: AssetRecord? {
        guard selectedAssetIDs.count == 1, let id = selectedAssetIDs.first else { return nil }
        return assets.first(where: { $0.id == id }) ?? allAssetsByID[id]
    }

    public var selectedAssets: [AssetRecord] {
        assets.filter { selectedAssetIDs.contains($0.id) }
    }

    public func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await engine.seedSampleLibraryIfEmpty()
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func applyDestination(_ destination: SidebarDestination) async {
        filter.folderID = nil
        filter.onlyInbox = false
        filter.onlyUntagged = false
        filter.onlyRecentDays = nil
        filter.onlyTrashed = false
        filter.includeTrashed = false
        filter.tags.removeAll()

        switch destination {
        case .allItems:
            break
        case .inbox:
            filter.onlyInbox = true
        case .untagged:
            filter.onlyUntagged = true
        case .recent:
            filter.onlyRecentDays = 14
            filter.sortBy = .newest
        case .trash:
            filter.onlyTrashed = true
            filter.includeTrashed = true
        case .folder(let folderID):
            filter.folderID = folderID
        case .tag(let tagName):
            filter.tags = [tagName]
        case .moodboardsHome, .moodboard:
            return
        }

        selectedAssetIDs.removeAll()
        await refreshAssets()
    }

    public func refreshAll() async {
        do {
            async let fetchedAssets = engine.fetchAssets(matching: filter)
            async let fetchedAll = engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))
            async let fetchedFolders = engine.fetchFolders()
            async let fetchedTags = engine.fetchTagCounts()
            async let fetchedInbox = engine.inboxCount()

            let (visible, all, folderList, tags, inbox) = try await (
                fetchedAssets, fetchedAll, fetchedFolders, fetchedTags, fetchedInbox
            )
            assets = visible
            allAssetsByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            folders = folderList
            tagCounts = tags
            inboxCount = inbox
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("refreshAll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func refreshAssets() async {
        do {
            assets = try await engine.fetchAssets(matching: filter)
            for asset in assets {
                allAssetsByID[asset.id] = asset
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshSidebarMetadata() async {
        do {
            async let fetchedFolders = engine.fetchFolders()
            async let fetchedTags = engine.fetchTagCounts()
            async let fetchedInbox = engine.inboxCount()
            let (folderList, tags, inbox) = try await (fetchedFolders, fetchedTags, fetchedInbox)
            folders = folderList
            tagCounts = tags
            inboxCount = inbox
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Folder CRUD

    @discardableResult
    public func createFolder(name: String, parentID: UUID? = nil) async -> FolderRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let folder = try await engine.createFolder(name: trimmed, parentID: parentID)
            await refreshSidebarMetadata()
            return folder
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func renameFolder(id: UUID, newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await engine.renameFolder(id: id, newName: trimmed)
            await refreshSidebarMetadata()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func deleteFolder(id: UUID) async {
        do {
            try await engine.deleteFolder(id: id)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Ingestion (Single Source of Truth)

    @discardableResult
    public func ingest(
        _ inputs: [CaptureInput],
        targetFolderID: UUID?,
        targetBoardID: UUID? = nil
    ) async -> [AssetRecord] {
        guard !inputs.isEmpty else { return [] }
        do {
            let created = try await engine.ingest(inputs, targetFolderID: targetFolderID, targetBoardID: targetBoardID)
            for item in created {
                allAssetsByID[item.id] = item
            }
            await refreshAll()
            return created
        } catch {
            lastError = error.localizedDescription
            libraryStoreLogger.error("Ingest failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Asset Patching & Batch Operations

    public func applyPatch(_ patch: AssetBatchPatch) async {
        guard !patch.assetIDs.isEmpty else { return }
        do {
            let updated = try await engine.updateAssets(patch)
            for item in updated {
                allAssetsByID[item.id] = item
            }
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func moveAssets(_ ids: [UUID], toFolderID folderID: UUID?) async {
        let assignment: FolderAssignment = folderID.map { .folder($0) } ?? .inbox
        await applyPatch(AssetBatchPatch(assetIDs: ids, folderAssignment: assignment))
    }

    public func setRating(_ rating: Int, for ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, rating: max(0, min(5, rating))))
    }

    public func addTags(_ tags: [String], to ids: [UUID]) async {
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        await applyPatch(AssetBatchPatch(assetIDs: ids, addTags: cleaned))
    }

    public func removeTag(_ tag: String, from ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, removeTags: [tag]))
    }

    public func acceptSuggestedTag(_ tag: String, for assetID: UUID) async {
        await applyPatch(AssetBatchPatch(assetIDs: [assetID], addTags: [tag], dismissSuggestedTags: [tag]))
    }

    public func acceptAllSuggestedTags(for ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, acceptSuggestedTags: true))
    }

    public func togglePinOffline(ids: [UUID], pinned: Bool) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, pinnedOffline: pinned))
    }

    public func trashAssets(_ ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, isTrashed: true))
        selectedAssetIDs.subtract(ids)
    }

    public func restoreAssets(_ ids: [UUID]) async {
        await applyPatch(AssetBatchPatch(assetIDs: ids, isTrashed: false))
        selectedAssetIDs.subtract(ids)
    }

    public func permanentlyDeleteAssets(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            try await engine.permanentlyDeleteAssets(ids: ids)
            for id in ids {
                allAssetsByID.removeValue(forKey: id)
                thumbnailLoader.invalidate(assetID: id)
            }
            selectedAssetIDs.subtract(ids)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Inspector Intelligence & Quick Jump

    public func refreshInspectorContext(for assetID: UUID?) {
        inspectorContextTask?.cancel()
        guard let assetID else {
            similarAssets = []
            suggestedFolder = nil
            return
        }
        inspectorContextTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let sim = self.engine.similarAssets(to: assetID, limit: 8)
                async let suggestion = self.engine.suggestFolder(for: assetID)
                let (simRes, folderRes) = try await (sim, suggestion)
                guard !Task.isCancelled else { return }
                self.similarAssets = simRes
                self.suggestedFolder = folderRes
            } catch {
                // Non-fatal in inspector context
            }
        }
    }

    public func analyzeLocally(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let updated = try await engine.analyzeAssetsLocally(ids: ids)
            for item in updated { allAssetsByID[item.id] = item }
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func enrichWithCloudAI(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let updated = try await engine.enrichAssetsWithCloudAI(ids: ids)
            for item in updated { allAssetsByID[item.id] = item }
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func quickJump(query: String, limit: Int = 24) async -> [QuickJumpMatch] {
        (try? await engine.quickJump(query: query, limit: limit)) ?? []
    }

    public func resolveOriginalURL(for assetID: UUID) async -> URL? {
        try? await engine.originalURL(for: assetID)
    }

    public func filterByColorHex(_ hex: String) async {
        filter.selectedColorHex = hex.uppercased()
        await refreshAssets()
    }
}

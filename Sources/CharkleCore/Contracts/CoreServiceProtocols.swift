import Foundation

/// Unified deep-module facade exposed by CharkleCore to CharkleCanvas and CharkleApp.
public protocol CharkleEngineProtocol: Sendable {
    // MARK: - Library & Inbox
    func fetchAssets(matching criteria: FilterCriteria) async throws -> [AssetRecord]
    func fetchAsset(id: UUID) async throws -> AssetRecord?
    func fetchFolders() async throws -> [FolderRecord]
    func fetchTagCounts() async throws -> [TagCount]
    func inboxCount() async throws -> Int

    func createFolder(name: String, parentID: UUID?) async throws -> FolderRecord
    func renameFolder(id: UUID, newName: String) async throws -> FolderRecord
    func deleteFolder(id: UUID) async throws

    func ingest(
        _ inputs: [CaptureInput],
        targetFolderID: UUID?,
        targetBoardID: UUID?
    ) async throws -> [AssetRecord]
    func updateAssets(_ patch: AssetBatchPatch) async throws -> [AssetRecord]
    func permanentlyDeleteAssets(ids: [UUID]) async throws

    func quickJump(query: String, limit: Int) async throws -> [QuickJumpMatch]
    func similarAssets(to assetID: UUID, limit: Int) async throws -> [ScoredAsset]
    func suggestFolder(for assetID: UUID) async throws -> FolderSuggestion?

    // MARK: - Media & Cache
    func thumbnailURL(for assetID: UUID, tier: ThumbnailTier) async -> URL?
    func originalURL(for assetID: UUID) async throws -> URL
    func cacheStats() async -> CacheStats
    func setCacheBudgetBytes(_ bytes: Int64) async
    func evictCacheNow() async throws -> CacheStats

    // MARK: - Moodboards
    func fetchBoards() async throws -> [MoodboardSummary]
    func fetchBoard(id: UUID) async throws -> MoodboardDocument?
    func proposeMoodboard(
        seed: MoodboardSeed,
        primaryCount: Int,
        candidateCount: Int
    ) async throws -> MoodboardProposal
    func saveBoard(_ document: MoodboardDocument) async throws -> MoodboardDocument
    func deleteBoard(id: UUID) async throws
    func setBoardPinnedOffline(id: UUID, pinned: Bool) async throws
    func extractBoardPalette(assetIDs: [UUID], count: Int) async throws -> [LabColor]
    func replacementCandidates(
        for assetID: UUID,
        excluding: Set<UUID>,
        boardContext: [UUID],
        limit: Int
    ) async throws -> [ScoredAsset]

    // MARK: - Intelligence
    func analyzeAssetsLocally(ids: [UUID]) async throws -> [AssetRecord]
    func enrichAssetsWithCloudAI(ids: [UUID]) async throws -> [AssetRecord]
    func aiConfig() async -> AIProviderConfig
    func saveAIConfig(_ config: AIProviderConfig, apiKey: String?) async throws
    func hasStoredAIKey(for provider: CloudAIProviderKind) async -> Bool

    // MARK: - Cloud & Local Storage Sync (Google Drive / WebDAV / Local Folder + Migration)
    func syncConfig() async -> DriveSyncConfig
    func saveSyncConfig(_ config: DriveSyncConfig) async throws
    func syncStatus() async -> SyncStatus
    func probeGDirectEnvironment() async -> GDirectEnvironmentSnapshot
    func runGDirectScan() async throws -> GDirectEnvironmentSnapshot
    func runGDirectMount(path: String?) async throws -> GDirectEnvironmentSnapshot
    func importGoogleOAuthSecret(from url: URL) async throws
    func importGoogleOAuthFromGDirect() async throws
    func hasGoogleOAuthClientConfig() async -> Bool
    func saveGoogleOAuthClientConfig(clientID: String, clientSecret: String) async throws
    func signInGoogleDrive() async throws -> DriveAccountInfo
    func signOutGoogleDrive() async throws
    func hasWebDAVPassword() async -> Bool
    func saveWebDAVPassword(_ password: String) async throws
    func testWebDAVConnection(config: DriveSyncConfig, password: String?) async throws -> DriveAccountInfo
    func migrateLibraryStorage(to targetConfig: DriveSyncConfig, webDAVPassword: String?) async throws -> StorageMigrationReport
    func syncNow() async throws -> SyncReport

    // MARK: - First-Launch Curated Demo
    func seedSampleLibraryIfEmpty() async throws -> Bool
}

public enum CharkleEngineFactory {
    /// Returns the live SQLite + MediaPipeline + DriveSync + Intelligence production engine.
    public static func makeDefault(appSupportDirectory: URL? = nil) throws -> any CharkleEngineProtocol {
        try LiveCharkleEngine.make(appSupportDirectory: appSupportDirectory)
    }
}

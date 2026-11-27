import Foundation

public nonisolated enum CharkleCoreNotifications {
    /// Posted when background post-ingest Vision / Cloud AI enrichment updates persisted assets.
    public static let libraryDidEnrichInBackground = Notification.Name("com.charkle.core.libraryDidEnrichInBackground")
}

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
    func moveFolder(id: UUID, newParentID: UUID?, insertAtIndex: Int?) async throws -> [FolderRecord]
    func updateFolderAppearance(id: UUID, colorHex: String?, customSymbol: String?) async throws -> FolderRecord

    func fetchSmartFolders() async throws -> [SmartFolderRecord]
    func saveSmartFolder(_ folder: SmartFolderRecord) async throws -> [SmartFolderRecord]
    func deleteSmartFolder(id: UUID) async throws -> [SmartFolderRecord]

    func ingest(
        _ inputs: [CaptureInput],
        targetFolderID: UUID?,
        targetBoardID: UUID?
    ) async throws -> [AssetRecord]
    func importMaterialPackage(
        at url: URL,
        targetFolderID: UUID?,
        targetBoardID: UUID?
    ) async throws -> MaterialPackageImportResult
    func importPureRefScene(
        at url: URL,
        targetFolderID: UUID?,
        createMoodboard: Bool
    ) async throws -> PureRefImportResult
    func exportAssetsToPureRef(
        assetIDs: [UUID],
        title: String,
        to destinationURL: URL
    ) async throws -> PureRefExportReport
    func exportMoodboardToPureRef(
        board: MoodboardDocument,
        to destinationURL: URL
    ) async throws -> PureRefExportReport
    func updateAssets(_ patch: AssetBatchPatch) async throws -> [AssetRecord]
    func permanentlyDeleteAssets(ids: [UUID]) async throws
    func scanDuplicateImages(
        scope: DeduplicationScanScope,
        sensitivity: DeduplicationSensitivity,
        mediaKinds: Set<MediaKind>?,
        onProgress: (@Sendable (DeduplicationScanProgress) async -> Void)?
    ) async throws -> DeduplicationScanReport
    func resolveDuplicateGroups(
        _ plans: [DeduplicationResolutionPlan],
        disposal: DuplicateDisposalMode,
        mergeMetadata: Bool
    ) async throws -> DeduplicationCleanupResult
    func markAssetOpened(id: UUID) async
    func refreshRichAsset(id: UUID) async throws -> AssetRecord
    func updateAssetCoverImage(id: UUID, imageData: Data) async throws -> AssetRecord
    func upgradeLegacyXiaohongshuCoversIfNeeded() async -> [UUID]

    func quickJump(query: String, limit: Int) async throws -> [QuickJumpMatch]
    func similarAssets(to assetID: UUID, limit: Int) async throws -> [ScoredAsset]
    func suggestFolder(for assetID: UUID) async throws -> FolderSuggestion?

    // MARK: - Media & Cache
    nonisolated func cachedThumbnailURL(for assetID: UUID, tier: ThumbnailTier) -> URL?
    nonisolated func cachedOriginalURL(for asset: AssetRecord) -> URL?
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
    func curateMoodboard(
        _ request: MoodboardCurationRequest,
        onStep: (@Sendable (MoodboardAgentStep) async -> Void)?
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
    func hydrateImageMetadataIfNeeded(id: UUID) async throws -> AssetRecord?
    func enrichAssetsWithCloudAI(ids: [UUID]) async throws -> [AssetRecord]
    func aiConfig() async -> AIProviderConfig
    func saveAIConfig(_ config: AIProviderConfig, apiKey: String?) async throws
    func hasStoredAIKey(for provider: CloudAIProviderKind) async -> Bool
    func testAIConnection(config: AIProviderConfig, apiKey: String?) async throws -> String
    func chatGPTSession() async -> ChatGPTAccountSession
    func signInWithChatGPT(reconsent: Bool, switchAccount: Bool) async throws -> ChatGPTAccountSession
    func disconnectChatGPT(resetRegistration: Bool) async throws
    func listChatGPTModels() async throws -> [ChatGPTModelInfo]

    // MARK: - Experimental TypeSafe System One (Jev) Visual Grounding
    func typeSafeConfig() async -> TypeSafeExperimentalConfig
    func saveTypeSafeConfig(_ config: TypeSafeExperimentalConfig, apiKey: String?) async throws
    func hasStoredTypeSafeKey() async -> Bool
    func testTypeSafeConnection(config: TypeSafeExperimentalConfig, apiKey: String?) async throws -> [TypeSafeModelInfo]
    func locateVisualRegion(assetID: UUID, query: String?) async throws -> VisualRegionResult
    func locateVisualMatch(referenceAssetID: UUID, in targetAssetID: UUID) async throws -> VisualRegionResult
    func detectCleanContentBounds(assetID: UUID) async throws -> CleanBoundsResult
    func extractSubjectPalette(assetID: UUID, query: String?) async throws -> SubjectPaletteResult
    func semanticSearch(query: String, criteria: FilterCriteria, limit: Int) async throws -> SemanticSearchReport
    func batchTriageInbox(assetIDs: [UUID], maxCount: Int) async throws -> [InboxTriageRecommendation]

    // MARK: - Cloud & Local Storage Sync (Google Drive / WebDAV / Local Folder + Migration)
    func syncConfig() async -> DriveSyncConfig
    func saveSyncConfig(_ config: DriveSyncConfig) async throws
    func syncStatus() async -> SyncStatus
    func probeGDirectEnvironment() async -> GDirectEnvironmentSnapshot
    func runGDirectScan() async throws -> GDirectEnvironmentSnapshot
    func runGDirectMount(path: String?) async throws -> GDirectEnvironmentSnapshot
    func runGDirectUnmount() async throws -> GDirectEnvironmentSnapshot
    func importGoogleOAuthSecret(from url: URL) async throws
    func importGoogleOAuthData(_ data: Data) async throws
    func importGoogleOAuthFromGDirect() async throws
    func hasGoogleOAuthClientConfig() async -> Bool
    func saveGoogleOAuthClientConfig(clientID: String, clientSecret: String) async throws
    func signInGoogleDrive() async throws -> DriveAccountInfo
    func signInGoogleDrive(
        presentAuthSession: @Sendable (URL, String) async throws -> URL
    ) async throws -> DriveAccountInfo
    func signOutGoogleDrive() async throws
    func hasWebDAVPassword() async -> Bool
    func saveWebDAVPassword(_ password: String) async throws
    func testWebDAVConnection(config: DriveSyncConfig, password: String?) async throws -> DriveAccountInfo
    func migrateLibraryStorage(to targetConfig: DriveSyncConfig, webDAVPassword: String?) async throws -> StorageMigrationReport
    func listGoogleDriveSharedFolders() async throws -> [RemoteDriveFile]
    func syncNow() async throws -> SyncReport
    func syncBackend(id: UUID) async throws -> SyncReport
    func probeICloudDriveAvailability() async -> ICloudDriveAvailability
    func saveBackendWebDAVPassword(_ password: String, for backendID: UUID) async throws
    func hasBackendWebDAVPassword(for backendID: UUID) async -> Bool
    func saveICloudBookmark(_ bookmarkData: Data?, displayPath: String, for backendID: UUID) async throws
    func hasICloudBookmark(for backendID: UUID) async -> Bool
    func testBackendConnection(_ profile: SyncBackendProfile, webDAVPassword: String?) async throws -> DriveAccountInfo

    // MARK: - First-Launch Curated Demo
    func seedSampleLibraryIfEmpty() async throws -> Bool
}

public extension CharkleEngineProtocol {
    func importMaterialPackage(
        at url: URL,
        targetFolderID: UUID?,
        targetBoardID: UUID?
    ) async throws -> MaterialPackageImportResult {
        let imported = try await ingest([.fileURL(url)], targetFolderID: targetFolderID, targetBoardID: targetBoardID)
        return MaterialPackageImportResult(
            packageName: url.deletingPathExtension().lastPathComponent,
            importedAssets: imported,
            createdFolderCount: 0,
            rootFolderID: imported.first?.folderID ?? targetFolderID
        )
    }

    func importPureRefScene(
        at url: URL,
        targetFolderID: UUID?,
        createMoodboard: Bool
    ) async throws -> PureRefImportResult {
        PureRefImportResult(
            sceneName: url.deletingPathExtension().lastPathComponent,
            formatVersion: "1.10",
            importedAssets: [],
            rootFolderID: targetFolderID
        )
    }

    func exportAssetsToPureRef(
        assetIDs: [UUID],
        title: String,
        to destinationURL: URL
    ) async throws -> PureRefExportReport {
        throw PureRefCodecError.encodingFailed("当前演示引擎不支持导出 PureRef 文件。")
    }

    func exportMoodboardToPureRef(
        board: MoodboardDocument,
        to destinationURL: URL
    ) async throws -> PureRefExportReport {
        throw PureRefCodecError.encodingFailed("当前演示引擎不支持导出 PureRef 文件。")
    }

    nonisolated func cachedThumbnailURL(for assetID: UUID, tier: ThumbnailTier) -> URL? {
        nil
    }

    nonisolated func cachedOriginalURL(for asset: AssetRecord) -> URL? {
        nil
    }

    func scanDuplicateImages(
        scope: DeduplicationScanScope,
        sensitivity: DeduplicationSensitivity,
        mediaKinds: Set<MediaKind>?,
        onProgress: (@Sendable (DeduplicationScanProgress) async -> Void)?
    ) async throws -> DeduplicationScanReport {
        DeduplicationScanReport(
            scannedAssetCount: 0,
            skippedNonVisualCount: 0,
            groups: [],
            totalDuplicateItems: 0,
            totalReclaimableBytes: 0,
            durationSeconds: 0
        )
    }

    func resolveDuplicateGroups(
        _ plans: [DeduplicationResolutionPlan],
        disposal: DuplicateDisposalMode,
        mergeMetadata: Bool
    ) async throws -> DeduplicationCleanupResult {
        DeduplicationCleanupResult(
            resolvedGroupCount: 0,
            removedAssetCount: 0,
            reclaimedBytes: 0,
            mergedMetadataCount: 0,
            updatedBoardCount: 0
        )
    }

    func markAssetOpened(id: UUID) async {}

    func moveFolder(id: UUID, newParentID: UUID?, insertAtIndex: Int?) async throws -> [FolderRecord] {
        try await fetchFolders()
    }

    func updateFolderAppearance(id: UUID, colorHex: String?, customSymbol: String?) async throws -> FolderRecord {
        guard let folder = try await fetchFolders().first(where: { $0.id == id }) else {
            throw NSError(domain: "CharkleCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Folder not found"])
        }
        return folder
    }

    func fetchSmartFolders() async throws -> [SmartFolderRecord] { [] }
    func saveSmartFolder(_ folder: SmartFolderRecord) async throws -> [SmartFolderRecord] { [] }
    func deleteSmartFolder(id: UUID) async throws -> [SmartFolderRecord] { [] }

    func refreshRichAsset(id: UUID) async throws -> AssetRecord {
        guard let asset = try await fetchAsset(id: id) else {
            throw NSError(domain: "CharkleCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset not found"])
        }
        return asset
    }

    func updateAssetCoverImage(id: UUID, imageData: Data) async throws -> AssetRecord {
        guard let asset = try await fetchAsset(id: id) else {
            throw NSError(domain: "CharkleCore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset not found"])
        }
        return asset
    }

    func upgradeLegacyXiaohongshuCoversIfNeeded() async -> [UUID] { [] }

    func hydrateImageMetadataIfNeeded(id: UUID) async throws -> AssetRecord? { nil }

    func testAIConnection(config: AIProviderConfig, apiKey: String?) async throws -> String {
        guard config.provider != .disabled else {
            throw LibraryDatabaseError("请先选择要测试的云端 AI 服务。")
        }
        return "AI 服务连接正常"
    }

    func importGoogleOAuthData(_ data: Data) async throws {
        throw DriveTransportError.notConfigured("当前引擎不支持导入 OAuth 凭据数据。")
    }

    func signInGoogleDrive(
        presentAuthSession: @Sendable (URL, String) async throws -> URL
    ) async throws -> DriveAccountInfo {
        try await signInGoogleDrive()
    }

    func syncBackend(id: UUID) async throws -> SyncReport {
        try await syncNow()
    }

    func probeICloudDriveAvailability() async -> ICloudDriveAvailability {
        ICloudDriveTransport.probeAvailability()
    }

    func saveBackendWebDAVPassword(_ password: String, for backendID: UUID) async throws {
        try await saveWebDAVPassword(password)
    }

    func hasBackendWebDAVPassword(for backendID: UUID) async -> Bool {
        await hasWebDAVPassword()
    }

    func saveICloudBookmark(_ bookmarkData: Data?, displayPath: String, for backendID: UUID) async throws {}

    func hasICloudBookmark(for backendID: UUID) async -> Bool {
        false
    }

    func testBackendConnection(_ profile: SyncBackendProfile, webDAVPassword: String?) async throws -> DriveAccountInfo {
        let single = profile.toSingleBackendConfig(inheriting: await syncConfig())
        if profile.mode == .webDAV {
            return try await testWebDAVConnection(config: single, password: webDAVPassword)
        }
        return DriveAccountInfo(email: profile.locationSummary, source: profile.mode.localizedLabel)
    }
}

public enum CharkleEngineFactory {
    /// Returns the live SQLite + MediaPipeline + DriveSync + Intelligence production engine.
    public static func makeDefault(appSupportDirectory: URL? = nil) throws -> any CharkleEngineProtocol {
        try LiveCharkleEngine.make(appSupportDirectory: appSupportDirectory)
    }
}

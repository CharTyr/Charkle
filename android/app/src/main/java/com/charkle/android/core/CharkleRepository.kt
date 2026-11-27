package com.charkle.android.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.put
import uniffi.charkle_android_ffi.AndroidEngineEventListener
import uniffi.charkle_android_ffi.AndroidEngineHandle
import uniffi.charkle_android_ffi.GoogleOAuthClientSummaryDto
import uniffi.charkle_android_ffi.GooglePkceStartDto

@OptIn(ExperimentalSerializationApi::class)
class CharkleRepository(
    private val engineDeferred: Deferred<AndroidEngineHandle>,
    scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) {
    constructor(engine: AndroidEngineHandle) : this(
        engineDeferred = CompletableDeferred(engine),
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    )

    internal val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        isLenient = true
        coerceInputValues = true
    }

    private val _events = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val events: SharedFlow<String> = _events.asSharedFlow()

    init {
        scope.launch(Dispatchers.IO) {
            runCatching { engineDeferred.await() }.onSuccess { engine ->
                engine.subscribeEvents(object : AndroidEngineEventListener {
                    override fun onEvent(eventJson: String) {
                        _events.tryEmit(eventJson)
                    }
                })
            }
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun completedEngineOrNull(): AndroidEngineHandle? {
        return if (engineDeferred.isCompleted && !engineDeferred.isCancelled) {
            runCatching { engineDeferred.getCompleted() }.getOrNull()
        } else {
            null
        }
    }

    private suspend fun awaitEngine(): AndroidEngineHandle = engineDeferred.await()

    suspend fun awaitReady() {
        awaitEngine()
    }

    fun engineVersion(): String = completedEngineOrNull()?.engineVersion() ?: "0.1.0"

    suspend fun engineVersionAsync(): String = withContext(Dispatchers.IO) {
        awaitEngine().engineVersion()
    }

    fun decodeEngineEvent(eventJson: String): EngineEventEnvelope? {
        return runCatching { json.decodeFromString<EngineEventEnvelope>(eventJson) }.getOrNull()
    }

    fun decodeSyncStatus(payload: JsonElement): SyncStatusDto? {
        return runCatching { json.decodeFromJsonElement<SyncStatusDto>(payload) }.getOrNull()
    }

    fun decodeUuidList(payload: JsonElement): List<String>? {
        return runCatching { json.decodeFromJsonElement<List<String>>(payload) }.getOrNull()
    }

    suspend fun seedSampleLibraryIfEmpty(): Boolean = withContext(Dispatchers.IO) {
        awaitEngine().seedSampleLibraryIfEmpty()
    }

    suspend fun fetchAssets(criteria: FilterCriteriaDto): List<AssetDto> = withContext(Dispatchers.IO) {
        val raw = awaitEngine().fetchAssetsJson(json.encodeToString(criteria))
        json.decodeFromString(raw)
    }

    suspend fun fetchSmartFolderAssets(
        smartFolderId: String,
        criteria: FilterCriteriaDto
    ): List<AssetDto> = withContext(Dispatchers.IO) {
        val raw = awaitEngine().fetchSmartFolderAssetsJson(
            smartFolderId = smartFolderId,
            criteriaJson = json.encodeToString(criteria)
        )
        json.decodeFromString(raw)
    }

    suspend fun fetchAsset(assetId: String): AssetDto? = withContext(Dispatchers.IO) {
        awaitEngine().fetchAssetJson(assetId)?.let { json.decodeFromString(it) }
    }

    suspend fun fetchFolders(): List<FolderDto> = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().fetchFoldersJson())
    }

    suspend fun createFolder(name: String, parentId: String? = null): FolderDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().createFolderJson(name, parentId))
    }

    suspend fun renameFolder(folderId: String, newName: String): FolderDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().renameFolderJson(folderId, newName))
    }

    suspend fun updateFolderAppearance(
        folderId: String,
        colorHex: String?,
        customSymbol: String? = null
    ): FolderDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().updateFolderAppearanceJson(folderId, colorHex, customSymbol))
    }

    suspend fun deleteFolder(folderId: String, trashContents: Boolean = false) = withContext(Dispatchers.IO) {
        awaitEngine().deleteFolder(folderId, trashContents)
    }

    suspend fun quickJump(query: String, limit: Int = 20): List<QuickJumpMatchDto> = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().quickJumpJson(query, limit.toUInt()))
    }

    suspend fun semanticSearchLocal(
        query: String,
        criteria: FilterCriteriaDto,
        limit: Int = 40
    ): SemanticSearchReportDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().semanticSearchLocalJson(query, json.encodeToString(criteria), limit.toUInt())
        json.decodeFromString(raw)
    }

    suspend fun hydrateImageMetadata(assetId: String): AssetDto? = withContext(Dispatchers.IO) {
        awaitEngine().hydrateImageMetadataJson(assetId)?.let { json.decodeFromString(it) }
    }

    suspend fun fetchSmartFolders(): List<SmartFolderDto> = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().fetchSmartFoldersJson())
    }

    suspend fun fetchTagCounts(): List<TagCountDto> = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().fetchTagCountsJson())
    }

    suspend fun fetchBoards(): List<MoodboardSummaryDto> = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().fetchBoardsJson())
    }

    suspend fun createBoard(title: String): MoodboardDocumentDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().createBoardJson(title))
    }

    suspend fun fetchBoard(boardId: String): MoodboardDocumentDto? = withContext(Dispatchers.IO) {
        awaitEngine().fetchBoardJson(boardId)?.let { json.decodeFromString(it) }
    }

    suspend fun saveBoard(document: MoodboardDocumentDto): MoodboardDocumentDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().saveBoardJson(json.encodeToString(document))
        json.decodeFromString(raw)
    }

    suspend fun deleteBoard(boardId: String) = withContext(Dispatchers.IO) {
        awaitEngine().deleteBoard(boardId)
    }

    suspend fun setBoardPinnedOffline(boardId: String, pinned: Boolean): MoodboardDocumentDto =
        withContext(Dispatchers.IO) {
            json.decodeFromString(awaitEngine().setBoardPinnedOfflineJson(boardId, pinned))
        }

    suspend fun solveEditorialLayout(
        document: MoodboardDocumentDto,
        containerWidth: Double
    ): EditorialLayoutResultDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().solveEditorialLayoutJson(json.encodeToString(document), containerWidth)
        json.decodeFromString(raw)
    }

    suspend fun exportBoardImageBytes(
        boardId: String,
        optionsJson: String = "{}"
    ): ByteArray = withContext(Dispatchers.IO) {
        awaitEngine().exportBoardImageBytes(boardId, optionsJson)
    }

    suspend fun exportBoardFigmaBridge(
        boardId: String,
        destinationPath: String,
        optionsJson: String = "{}"
    ): FigmaBridgeExportReportDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().exportBoardFigmaBridgeJson(boardId, optionsJson, destinationPath)
        json.decodeFromString(raw)
    }

    // =========================================================================
    // Pinterest Spatial Explorer
    // =========================================================================

    suspend fun pinterestExistingImportedPinIds(): Set<String> = withContext(Dispatchers.IO) {
        awaitEngine().pinterestExistingImportedPinIds().toSet()
    }

    suspend fun pinterestComputeSpatialLayout(
        pins: List<PinterestPinDto>,
        cardWidth: Double = 224.0,
        gap: Double = 16.0
    ): List<PinterestSpatialCardDto> = withContext(Dispatchers.IO) {
        val raw = awaitEngine().pinterestComputeSpatialLayoutJson(json.encodeToString(pins), cardWidth, gap)
        json.decodeFromString(raw)
    }

    suspend fun pinterestCheckSession(cookieHeader: String): PinterestAccountDto? = withContext(Dispatchers.IO) {
        awaitEngine().pinterestCheckSessionJson(cookieHeader)?.let { json.decodeFromString(it) }
    }

    suspend fun pinterestFetchFeed(
        cookieHeader: String,
        sourceJson: String,
        bookmark: String? = null,
        pageSize: Int = 28
    ): PinterestFeedPageDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().pinterestFetchFeedJson(cookieHeader, sourceJson, bookmark, pageSize.toUInt())
        json.decodeFromString(raw)
    }

    suspend fun pinterestFetchUserBoards(
        cookieHeader: String,
        username: String
    ): List<PinterestBoardDto> = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().pinterestFetchUserBoardsJson(cookieHeader, username))
    }

    suspend fun pinterestFetchPinDetail(
        cookieHeader: String,
        pin: PinterestPinDto
    ): PinterestPinDetailResultDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().pinterestFetchPinDetailJson(cookieHeader, json.encodeToString(pin))
        json.decodeFromString(raw)
    }

    suspend fun pinterestImportPins(
        pins: List<PinterestPinDto>,
        targetFolderId: String? = null,
        extraTags: List<String> = emptyList(),
        skipDuplicates: Boolean = true
    ): PinterestBatchImportReportDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().pinterestImportPinsJson(
            json.encodeToString(pins),
            targetFolderId,
            extraTags,
            skipDuplicates
        )
        json.decodeFromString(raw)
    }

    suspend fun pinterestImportBoards(
        cookieHeader: String,
        boards: List<PinterestBoardDto>,
        destinationJson: String,
        extraTags: List<String> = emptyList(),
        skipDuplicates: Boolean = true
    ): PinterestBoardsImportReportDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().pinterestImportBoardsJson(
            cookieHeader,
            json.encodeToString(boards),
            destinationJson,
            extraTags,
            skipDuplicates
        )
        json.decodeFromString(raw)
    }

    suspend fun inboxCount(): Int = withContext(Dispatchers.IO) {
        awaitEngine().inboxCount().toInt()
    }

    suspend fun suggestFolder(assetId: String): FolderSuggestionDto? = withContext(Dispatchers.IO) {
        awaitEngine().suggestFolderJson(assetId)?.let { json.decodeFromString(it) }
    }

    suspend fun similarAssets(assetId: String, limit: Int = 12): List<ScoredAssetDto> = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().similarAssetsJson(assetId, limit.toUInt()))
    }

    suspend fun markAssetOpened(assetId: String): AssetDto? = withContext(Dispatchers.IO) {
        awaitEngine().markAssetOpenedJson(assetId)?.let { json.decodeFromString(it) }
    }

    suspend fun updateAssets(
        assetIds: List<String>,
        title: String? = null,
        notes: String? = null,
        rating: Int? = null,
        addTags: List<String> = emptyList(),
        removeTags: List<String> = emptyList(),
        folderId: String? = null,
        moveToInbox: Boolean = false,
        pinnedOffline: Boolean? = null,
        isTrashed: Boolean? = null
    ): List<AssetDto> = withContext(Dispatchers.IO) {
        val patch = buildJsonObject {
            put("assetIDs", buildJsonArray { assetIds.forEach { add(JsonPrimitive(it)) } })
            title?.let { put("title", it) }
            notes?.let { put("notes", it) }
            rating?.let { put("rating", it) }
            if (addTags.isNotEmpty()) {
                put("addTags", buildJsonArray { addTags.forEach { add(JsonPrimitive(it)) } })
            }
            if (removeTags.isNotEmpty()) {
                put("removeTags", buildJsonArray { removeTags.forEach { add(JsonPrimitive(it)) } })
            }
            when {
                moveToInbox -> put("folderAssignment", JsonPrimitive("inbox"))
                folderId != null -> put(
                    "folderAssignment",
                    JsonObject(mapOf("folder" to JsonPrimitive(folderId)))
                )
            }
            pinnedOffline?.let { put("pinnedOffline", it) }
            isTrashed?.let { put("isTrashed", it) }
        }
        val raw = awaitEngine().updateAssetsJson(patch.toString())
        json.decodeFromString(raw)
    }

    suspend fun permanentlyDeleteAssets(assetIds: List<String>) = withContext(Dispatchers.IO) {
        awaitEngine().permanentlyDeleteAssets(assetIds)
    }

    suspend fun ingestLocalFiles(
        paths: List<String>,
        targetFolderId: String? = null,
        targetBoardId: String? = null
    ): List<AssetDto> = withContext(Dispatchers.IO) {
        val raw = awaitEngine().ingestLocalFilesJson(paths, targetFolderId, targetBoardId)
        json.decodeFromString(raw)
    }

    suspend fun ingestWebUrl(
        url: String,
        title: String? = null,
        notes: String? = null,
        targetFolderId: String? = null
    ): List<AssetDto> = withContext(Dispatchers.IO) {
        val raw = awaitEngine().ingestWebUrlJson(url, title, notes, targetFolderId)
        json.decodeFromString(raw)
    }

    suspend fun ingestImageBytes(
        bytes: ByteArray,
        suggestedName: String,
        sourceUrl: String? = null,
        targetFolderId: String? = null
    ): List<AssetDto> = withContext(Dispatchers.IO) {
        val raw = awaitEngine().ingestImageBytesJson(bytes, suggestedName, sourceUrl, targetFolderId)
        json.decodeFromString(raw)
    }

    suspend fun resolveMediaPaths(assetIds: List<String>): Map<String, CachedMediaPathsDto> =
        withContext(Dispatchers.IO) {
            if (assetIds.isEmpty()) return@withContext emptyMap()
            val raw = awaitEngine().resolveMediaPathsJson(assetIds)
            json.decodeFromString(raw)
        }

    fun cachedThumbnailPath(assetId: String, previewTier: Boolean = false): String? {
        val eng = completedEngineOrNull() ?: return null
        return runCatching { eng.cachedThumbnailPath(assetId, previewTier) }.getOrNull()
    }

    fun cachedOriginalPath(assetId: String): String? {
        val eng = completedEngineOrNull() ?: return null
        return runCatching { eng.cachedOriginalPath(assetId) }.getOrNull()
    }

    suspend fun cachedOriginalPathAsync(assetId: String): String? = withContext(Dispatchers.IO) {
        runCatching { awaitEngine().cachedOriginalPath(assetId) }.getOrNull()
    }

    suspend fun originalPathOrDownload(assetId: String): String = withContext(Dispatchers.IO) {
        awaitEngine().originalPathOrDownload(assetId)
    }

    suspend fun cacheStats(): CacheStatsDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().cacheStatsJson())
    }

    suspend fun setCacheBudgetBytes(bytes: Long): Long = withContext(Dispatchers.IO) {
        awaitEngine().setCacheBudgetBytes(bytes)
    }

    suspend fun evictCacheNow(): CacheStatsDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().evictCacheNowJson())
    }

    suspend fun syncConfig(): DriveSyncConfigDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().syncConfigJson())
    }

    suspend fun saveSyncConfig(config: DriveSyncConfigDto) = withContext(Dispatchers.IO) {
        awaitEngine().saveSyncConfigJson(json.encodeToString(config))
    }

    suspend fun syncStatus(): SyncStatusDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().syncStatusJson())
    }

    suspend fun syncNow(): SyncReportDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().syncNowJson())
    }

    suspend fun syncBackend(backendId: String): SyncReportDto = withContext(Dispatchers.IO) {
        json.decodeFromString(awaitEngine().syncBackendJson(backendId))
    }

    suspend fun testBackendConnection(
        profile: SyncBackendProfileDto,
        webdavPassword: String? = null
    ): DriveAccountInfoDto = withContext(Dispatchers.IO) {
        val raw = awaitEngine().testBackendConnectionJson(json.encodeToString(profile), webdavPassword)
        json.decodeFromString(raw)
    }

    suspend fun hasGoogleOAuthClient(): Boolean = withContext(Dispatchers.IO) {
        awaitEngine().hasGoogleOauthClient()
    }

    suspend fun saveGoogleOAuthClientId(
        clientId: String,
        clientSecret: String? = null
    ): GoogleOAuthClientSummaryDto = withContext(Dispatchers.IO) {
        awaitEngine().saveGoogleOauthClientId(clientId, clientSecret)
    }

    suspend fun importGoogleOAuthClientJson(rawJson: ByteArray): GoogleOAuthClientSummaryDto =
        withContext(Dispatchers.IO) {
            awaitEngine().importGoogleOauthClientJson(rawJson)
        }

    suspend fun googleOAuthSignOut() = withContext(Dispatchers.IO) {
        awaitEngine().googleOauthSignOut()
    }

    suspend fun prepareGooglePkceAuth(
        redirectUri: String,
        fullDriveScope: Boolean = true
    ): GooglePkceStartDto = withContext(Dispatchers.IO) {
        awaitEngine().prepareGooglePkceAuth(redirectUri, fullDriveScope)
    }

    suspend fun completeGooglePkceAuth(
        code: String,
        codeVerifier: String,
        redirectUri: String
    ) = withContext(Dispatchers.IO) {
        awaitEngine().completeGooglePkceAuth(code, codeVerifier, redirectUri)
    }

    suspend fun saveBackendWebDavPassword(backendId: String, password: String) = withContext(Dispatchers.IO) {
        awaitEngine().saveBackendWebdavPassword(backendId, password)
    }

    suspend fun hasBackendWebDavPassword(backendId: String): Boolean = withContext(Dispatchers.IO) {
        awaitEngine().hasBackendWebdavPassword(backendId)
    }
}

package com.charkle.android.store

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.charkle.android.core.AssetDto
import com.charkle.android.core.CacheStatsDto
import com.charkle.android.core.CachedMediaPathsDto
import com.charkle.android.core.CharkleRepository
import com.charkle.android.core.DriveSyncConfigDto
import com.charkle.android.core.EditorialLayoutResultDto
import com.charkle.android.core.FigmaBridgeExportReportDto
import com.charkle.android.core.FilterCriteriaDto
import com.charkle.android.core.FolderDto
import com.charkle.android.core.FolderSuggestionDto
import com.charkle.android.core.MoodboardDocumentDto
import com.charkle.android.core.MoodboardSummaryDto
import com.charkle.android.core.QuickJumpMatchDto
import com.charkle.android.core.ScoredAssetDto
import com.charkle.android.core.SemanticSearchReportDto
import com.charkle.android.core.SmartFolderDto
import com.charkle.android.core.SyncBackendProfileDto
import com.charkle.android.core.SyncStatusDto
import com.charkle.android.core.TagCountDto
import com.charkle.android.designsystem.CharkleAppearanceMode
import com.charkle.android.system.CharkleSyncWorker
import com.charkle.android.system.InspirationGlanceWidget
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import uniffi.charkle_android_ffi.AndroidSecretVault
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

sealed interface LibraryScope {
    data object AllItems : LibraryScope
    data object Inbox : LibraryScope
    data object Recent : LibraryScope
    data object Untagged : LibraryScope
    data object Trash : LibraryScope
    data class Folder(val folderId: String) : LibraryScope
    data class SmartFolder(val smartFolderId: String) : LibraryScope
    data class Tag(val tag: String) : LibraryScope
}

enum class PrimaryTab(val id: String, val label: String) {
    Library("library", "素材库"),
    Inbox("inbox", "收件箱"),
    Moodboards("moodboards", "情绪板")
}

data class AppToast(
    val id: Long = System.nanoTime(),
    val message: String,
    val actionLabel: String? = null,
    val onAction: (() -> Unit)? = null
)

data class CharkleUiState(
    val isBootstrapped: Boolean = false,
    val isLoading: Boolean = true,
    val activeTab: PrimaryTab = PrimaryTab.Library,
    val scope: LibraryScope = LibraryScope.AllItems,
    val assets: List<AssetDto> = emptyList(),
    val inboxAssets: List<AssetDto> = emptyList(),
    val folders: List<FolderDto> = emptyList(),
    val smartFolders: List<SmartFolderDto> = emptyList(),
    val boards: List<MoodboardSummaryDto> = emptyList(),
    val tagCounts: List<TagCountDto> = emptyList(),
    val inboxCount: Int = 0,
    val criteria: FilterCriteriaDto = FilterCriteriaDto(),
    val columnCount: Int = 2,
    val isMultiSelectMode: Boolean = false,
    val selectedAssetIds: Set<String> = emptySet(),
    val inspectedAssetId: String? = null,
    val isTabletInspectorVisible: Boolean = true,
    val activeMoodboardId: String? = null,
    val highlightedAssetId: String? = null,
    val showPinterestExplore: Boolean = false,
    val pendingOpenCapture: Boolean = false,
    val pendingOpenAssetId: String? = null,
    val appearanceMode: CharkleAppearanceMode = CharkleAppearanceMode.System,
    val followSystemAccentOnControls: Boolean = false,
    val defaultColorProofing: Boolean = false,
    val syncConfig: DriveSyncConfigDto = DriveSyncConfigDto(),
    val syncStatus: SyncStatusDto = SyncStatusDto(),
    val hasGoogleOAuthClient: Boolean = false,
    val cacheStats: CacheStatsDto = CacheStatsDto(),
    val isSyncing: Boolean = false,
    val isIngesting: Boolean = false,
    val mediaCacheRevision: Long = 0L,
    val toast: AppToast? = null,
    val engineVersion: String = "0.1.0"
) {
    val currentScopeTitle: String
        get() = when (val s = scope) {
            LibraryScope.AllItems -> "全部素材"
            LibraryScope.Inbox -> "收件箱"
            LibraryScope.Recent -> "最近浏览"
            LibraryScope.Untagged -> "未打标签"
            LibraryScope.Trash -> "回收站"
            is LibraryScope.Folder -> folders.firstOrNull {
                it.id.equals(s.folderId, ignoreCase = true)
            }?.name ?: "文件夹"
            is LibraryScope.SmartFolder -> smartFolders.firstOrNull {
                it.id.equals(s.smartFolderId, ignoreCase = true)
            }?.name ?: "智能文件夹"
            is LibraryScope.Tag -> "#${s.tag}"
        }

    val activeFolderIdForCapture: String?
        get() = (scope as? LibraryScope.Folder)?.folderId
}

internal fun normalizeUuidKey(id: String): String = id.trim().uppercase(Locale.ROOT)

/**
 * Lock-free in-memory cache of resolved thumbnail & original file paths populated strictly on IO threads,
 * eliminating synchronous FFI roundtrips, SQLite locks, and `File.exists()` syscalls on Compose's main thread.
 */
internal class MediaPathCache(
    private val maxEntries: Int = 8192
) {
    private val entries = ConcurrentHashMap<String, CachedMediaPathsDto>()

    fun contains(assetId: String): Boolean = entries.containsKey(normalizeUuidKey(assetId))

    fun thumbnailPath(assetId: String, previewTier: Boolean): String? {
        val entry = entries[normalizeUuidKey(assetId)] ?: return null
        return if (previewTier) {
            entry.previewThumbPath ?: entry.gridThumbPath
        } else {
            entry.gridThumbPath ?: entry.previewThumbPath
        }
    }

    fun originalOrThumbPath(assetId: String): String? {
        val entry = entries[normalizeUuidKey(assetId)] ?: return null
        return entry.originalPath ?: entry.previewThumbPath ?: entry.gridThumbPath
    }

    fun putAll(batch: Map<String, CachedMediaPathsDto>) {
        if (batch.isEmpty()) return
        if (entries.size + batch.size > maxEntries) {
            entries.clear()
        }
        batch.forEach { (rawId, paths) ->
            entries[normalizeUuidKey(rawId)] = paths
        }
    }

    fun markResolvedEmpty(assetIds: Collection<String>, resolved: Map<String, CachedMediaPathsDto>) {
        if (entries.size + assetIds.size > maxEntries) {
            entries.clear()
        }
        assetIds.forEach { rawId ->
            val key = normalizeUuidKey(rawId)
            entries[key] = resolved[key] ?: CachedMediaPathsDto()
        }
    }

    fun updateOriginalPath(assetId: String, originalPath: String?) {
        val key = normalizeUuidKey(assetId)
        val existing = entries[key] ?: CachedMediaPathsDto()
        entries[key] = existing.copy(originalPath = originalPath)
    }

    fun clearOriginalPaths() {
        entries.keys.forEach { key ->
            entries.computeIfPresent(key) { _, cur -> cur.copy(originalPath = null) }
        }
    }

    fun invalidate(assetIds: Collection<String>) {
        assetIds.forEach { entries.remove(normalizeUuidKey(it)) }
    }

    fun size(): Int = entries.size
}

@Serializable
internal data class PendingPkceSession(
    val codeVerifier: String,
    val state: String,
    val redirectUri: String,
    val expiresAtMs: Long
)

internal sealed interface OAuthRedirectResult {
    data class Authorized(val code: String, val session: PendingPkceSession) : OAuthRedirectResult
    data class Failed(val message: String, val clearSession: Boolean) : OAuthRedirectResult
}

internal fun evaluateOAuthRedirect(
    code: String?,
    returnedState: String?,
    oauthError: String?,
    session: PendingPkceSession?,
    nowMs: Long
): OAuthRedirectResult {
    if (!oauthError.isNullOrBlank()) {
        val msg = if (oauthError.equals("access_denied", ignoreCase = true)) {
            "Google 授权已取消"
        } else {
            "Google 授权失败：$oauthError"
        }
        return OAuthRedirectResult.Failed(msg, clearSession = true)
    }
    if (code.isNullOrBlank()) {
        return OAuthRedirectResult.Failed("Google 授权已取消", clearSession = true)
    }
    if (session == null) {
        return OAuthRedirectResult.Failed("授权会话已过期，请重新点击登录", clearSession = true)
    }
    if (nowMs > session.expiresAtMs) {
        return OAuthRedirectResult.Failed("授权会话已超时，请重新点击登录", clearSession = true)
    }
    if (returnedState != session.state) {
        return OAuthRedirectResult.Failed("OAuth 安全校验不匹配，请重试", clearSession = false)
    }
    return OAuthRedirectResult.Authorized(code.trim(), session)
}

internal fun sanitizeStagedFileName(
    displayName: String?,
    derivedExtension: String?,
    fallbackTimestampMs: Long = System.currentTimeMillis()
): String {
    val rawLeaf = displayName
        ?.trim()
        ?.substringAfterLast('/')
        ?.substringAfterLast('\\')
        ?.replace("..", "_")
        ?.replace(Regex("[^\\p{L}\\p{N}._-]"), "_")
        ?.trim('.', '_')
        .orEmpty()

    val cleanExt = derivedExtension
        ?.trim()
        ?.trimStart('.')
        ?.lowercase(Locale.ROOT)
        ?.filter { it.isLetterOrDigit() }
        ?.take(12)
        ?.takeIf { it.isNotEmpty() }

    if (rawLeaf.isEmpty()) {
        return "capture_$fallbackTimestampMs.${cleanExt ?: "bin"}"
    }
    val hasExt = rawLeaf.contains('.') && rawLeaf.substringAfterLast('.').let { ext ->
        ext.length in 1..10 && ext.all { it.isLetterOrDigit() }
    }
    return if (hasExt || cleanExt == null) rawLeaf else "$rawLeaf.$cleanExt"
}

internal fun buildEffectiveCriteria(scope: LibraryScope, base: FilterCriteriaDto): FilterCriteriaDto {
    val cleanBase = base.copy(
        folderId = null,
        includeSubfolders = true,
        onlyInbox = false,
        onlyUntagged = false,
        onlyRecentDays = null,
        onlyTrashed = false,
        includeTrashed = false
    )
    return when (scope) {
        LibraryScope.AllItems -> cleanBase
        LibraryScope.Inbox -> cleanBase.copy(onlyInbox = true)
        LibraryScope.Recent -> cleanBase.copy(onlyRecentDays = 14)
        LibraryScope.Untagged -> cleanBase.copy(onlyUntagged = true)
        LibraryScope.Trash -> cleanBase.copy(onlyTrashed = true, includeTrashed = true)
        is LibraryScope.Folder -> cleanBase.copy(folderId = scope.folderId, includeSubfolders = true)
        is LibraryScope.SmartFolder -> cleanBase
        is LibraryScope.Tag -> cleanBase.copy(tags = cleanBase.tags + scope.tag)
    }
}

internal fun collectFolderSubtreeIds(rootFolderId: String, folders: List<FolderDto>): Set<String> {
    val targetRoot = normalizeUuidKey(rootFolderId)
    val childrenByParent = folders.groupBy { it.parentId?.let(::normalizeUuidKey) }
    val visited = mutableSetOf<String>()
    val stack = ArrayDeque<String>()
    stack.add(targetRoot)
    while (stack.isNotEmpty()) {
        val current = stack.removeLast()
        if (!visited.add(current)) continue
        childrenByParent[current].orEmpty().forEach { child ->
            stack.add(normalizeUuidKey(child.id))
        }
    }
    return visited
}

class CharkleAppStore(
    private val context: Context,
    val repository: CharkleRepository,
    private val vault: AndroidSecretVault? = null
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val prefs = context.getSharedPreferences("charkle_ui_prefs", Context.MODE_PRIVATE)
    private val mediaPathCache = MediaPathCache()
    private val pkceJson = Json { ignoreUnknownKeys = true }

    private val _state = MutableStateFlow(
        CharkleUiState(
            columnCount = prefs.getInt("column_count", 2).coerceIn(1, 7),
            appearanceMode = CharkleAppearanceMode.entries.getOrElse(
                prefs.getInt("appearance_mode", 0)
            ) { CharkleAppearanceMode.System },
            followSystemAccentOnControls = prefs.getBoolean("follow_system_accent", false),
            defaultColorProofing = prefs.getBoolean("default_color_proofing", false),
            engineVersion = repository.engineVersion()
        )
    )
    val state: StateFlow<CharkleUiState> = _state.asStateFlow()

    private val bootstrapped = AtomicBoolean(false)
    private val syncInFlight = AtomicBoolean(false)
    private val activeIngestCount = AtomicInteger(0)
    private val libraryGeneration = AtomicLong(0L)
    private val assetsGeneration = AtomicLong(0L)
    private val inboxGeneration = AtomicLong(0L)

    private var toastJob: Job? = null
    private var searchDebounceJob: Job? = null
    private var assetsLoadJob: Job? = null
    private var inboxLoadJob: Job? = null
    private var libraryLoadJob: Job? = null
    private var eventReloadCoalesceJob: Job? = null
    private var widgetRefreshJob: Job? = null
    private var highlightJob: Job? = null
    private var mediaPrefetchJob: Job? = null
    private val pendingPrefetchIds = ConcurrentHashMap.newKeySet<String>()

    @Volatile
    private var pendingGooglePkce: PendingPkceSession? = null

    init {
        scope.launch {
            repository.events.collect { rawEvent ->
                handleEngineEvent(rawEvent)
            }
        }
    }

    private fun handleEngineEvent(rawEvent: String) {
        val envelope = repository.decodeEngineEvent(rawEvent)
        if (envelope == null) {
            scheduleCoalescedLibraryReload()
            return
        }
        when (envelope.type) {
            "syncStatus" -> {
                val payload = envelope.payload ?: return
                val status = repository.decodeSyncStatus(payload) ?: return
                _state.update { it.copy(syncStatus = status) }
            }
            "syncProgressiveThumbnails" -> {
                val ids = envelope.payload?.let(repository::decodeUuidList).orEmpty()
                if (ids.isNotEmpty()) {
                    scope.launch {
                        warmMediaPaths(ids)
                        bumpMediaCacheRevision()
                    }
                }
            }
            else -> {
                scheduleCoalescedLibraryReload()
            }
        }
    }

    private fun scheduleCoalescedLibraryReload() {
        eventReloadCoalesceJob?.cancel()
        eventReloadCoalesceJob = scope.launch {
            delay(80)
            reloadLibrary(quiet = true)
        }
    }

    private fun scheduleWidgetRefresh() {
        widgetRefreshJob?.cancel()
        widgetRefreshJob = scope.launch(Dispatchers.IO) {
            delay(1500)
            InspirationGlanceWidget.updateAllWidgets(context)
        }
    }

    fun bootstrap() {
        if (!bootstrapped.compareAndSet(false, true)) return
        _state.update { it.copy(isBootstrapped = true, isLoading = true) }
        scope.launch {
            val initResult = runCatching {
                repository.awaitReady()
                val version = repository.engineVersionAsync()
                _state.update { it.copy(engineVersion = version) }
                repository.seedSampleLibraryIfEmpty()
            }
            if (initResult.isFailure) {
                _state.update { it.copy(isLoading = false) }
                showToast("初始化本地素材库失败：${initResult.exceptionOrNull()?.message ?: "未知错误"}")
                return@launch
            }
            reloadLibrary(quiet = false)
            loadSyncAndStorage()
        }
    }

    fun selectTab(tab: PrimaryTab) {
        _state.update { it.copy(activeTab = tab, isMultiSelectMode = false, selectedAssetIds = emptySet()) }
        if (tab == PrimaryTab.Inbox) {
            scheduleInboxReload()
        }
    }

    fun selectScope(newScope: LibraryScope) {
        searchDebounceJob?.cancel()
        _state.update {
            it.copy(
                activeTab = PrimaryTab.Library,
                scope = newScope,
                isMultiSelectMode = false,
                selectedAssetIds = emptySet()
            )
        }
        scheduleAssetsReload()
    }

    fun setSearchQuery(query: String) {
        _state.update { it.copy(criteria = it.criteria.copy(searchQuery = query)) }
        searchDebounceJob?.cancel()
        assetsLoadJob?.cancel()
        searchDebounceJob = scope.launch {
            delay(140)
            reloadAssetsNow()
        }
    }

    fun setColorFilter(hex: String?) {
        searchDebounceJob?.cancel()
        _state.update { it.copy(criteria = it.criteria.copy(selectedColorHex = hex)) }
        scheduleAssetsReload()
    }

    fun toggleColorFilter(hex: String) {
        val current = _state.value.criteria.selectedColorHex
        setColorFilter(if (current.equals(hex, ignoreCase = true)) null else hex)
    }

    fun setColorTolerance(tolerance: Double) {
        _state.update { it.copy(criteria = it.criteria.copy(colorTolerance = tolerance.coerceIn(10.0, 55.0))) }
        searchDebounceJob?.cancel()
        assetsLoadJob?.cancel()
        searchDebounceJob = scope.launch {
            delay(100)
            reloadAssetsNow()
        }
    }

    fun toggleMediaKindFilter(kind: String) {
        searchDebounceJob?.cancel()
        val current = _state.value.criteria.kinds
        val next = if (kind in current) current - kind else current + kind
        _state.update { it.copy(criteria = it.criteria.copy(kinds = next)) }
        scheduleAssetsReload()
    }

    fun setMinRatingFilter(minRating: Int) {
        searchDebounceJob?.cancel()
        _state.update { it.copy(criteria = it.criteria.copy(minRating = minRating)) }
        scheduleAssetsReload()
    }

    fun setSortOrder(sortBy: String) {
        searchDebounceJob?.cancel()
        _state.update { it.copy(criteria = it.criteria.copy(sortBy = sortBy)) }
        scheduleAssetsReload()
    }

    fun clearAllFilters() {
        searchDebounceJob?.cancel()
        _state.update { it.copy(criteria = FilterCriteriaDto()) }
        scheduleAssetsReload()
    }

    fun setColumnCount(cols: Int) {
        val clamped = cols.coerceIn(1, 7)
        prefs.edit().putInt("column_count", clamped).apply()
        _state.update { it.copy(columnCount = clamped) }
    }

    fun selectInspectedAsset(assetId: String?) {
        _state.update { it.copy(inspectedAssetId = assetId) }
    }

    fun toggleTabletInspector() {
        _state.update { it.copy(isTabletInspectorVisible = !it.isTabletInspectorVisible) }
    }

    fun openPinterestExplore() {
        _state.update { it.copy(showPinterestExplore = true) }
    }

    fun closePinterestExplore() {
        _state.update { it.copy(showPinterestExplore = false) }
    }

    fun requestOpenCaptureFromIntent() {
        _state.update { it.copy(pendingOpenCapture = true) }
    }

    fun consumePendingOpenCapture() {
        _state.update { it.copy(pendingOpenCapture = false) }
    }

    fun requestOpenAssetFromIntent(assetId: String) {
        val cleanId = normalizeUuidKey(assetId)
        if (cleanId.isEmpty()) return
        searchDebounceJob?.cancel()
        _state.update {
            it.copy(
                activeTab = PrimaryTab.Library,
                scope = LibraryScope.AllItems,
                criteria = FilterCriteriaDto(),
                activeMoodboardId = null,
                showPinterestExplore = false,
                pendingOpenAssetId = cleanId
            )
        }
        scheduleAssetsReload()
    }

    fun consumePendingOpenAsset() {
        _state.update { it.copy(pendingOpenAssetId = null) }
    }

    fun openMoodboard(boardId: String) {
        _state.update { it.copy(activeMoodboardId = boardId) }
    }

    fun closeMoodboard() {
        _state.update { it.copy(activeMoodboardId = null) }
        reloadLibrary(quiet = true)
    }

    fun createMoodboard(title: String, openImmediately: Boolean = true) {
        scope.launch {
            runCatching { repository.createBoard(title) }
                .onSuccess { doc ->
                    reloadLibrary(quiet = true)
                    showToast("已创建情绪板「${doc.title}」")
                    if (openImmediately) {
                        _state.update { it.copy(activeMoodboardId = doc.id) }
                    }
                }
                .onFailure { showToast("创建情绪板失败：${it.message}") }
        }
    }

    fun renameMoodboard(boardId: String, newTitle: String) {
        val clean = newTitle.trim()
        if (clean.isEmpty()) return
        scope.launch {
            runCatching {
                val doc = repository.fetchBoard(boardId) ?: return@runCatching null
                repository.saveBoard(doc.copy(title = clean))
            }.onSuccess { saved ->
                if (saved != null) {
                    reloadLibrary(quiet = true)
                    showToast("已重命名为「${saved.title}」")
                }
            }.onFailure { showToast("重命名失败：${it.message}") }
        }
    }

    fun deleteMoodboard(boardId: String) {
        scope.launch {
            runCatching { repository.deleteBoard(boardId) }
                .onSuccess {
                    if (_state.value.activeMoodboardId == boardId) {
                        _state.update { it.copy(activeMoodboardId = null) }
                    }
                    reloadLibrary(quiet = true)
                    showToast("已删除情绪板")
                }
                .onFailure { showToast("删除情绪板失败：${it.message}") }
        }
    }

    fun toggleMoodboardPinnedOffline(boardId: String, pinned: Boolean) {
        scope.launch {
            runCatching { repository.setBoardPinnedOffline(boardId, pinned) }
                .onSuccess {
                    reloadLibrary(quiet = true)
                    showToast(if (pinned) "已离线置顶该情绪板" else "已取消情绪板离线置顶")
                }
        }
    }

    suspend fun loadMoodboard(boardId: String): MoodboardDocumentDto? {
        val doc = runCatching { repository.fetchBoard(boardId) }.getOrNull() ?: return null
        val refIds = doc.nodes.mapNotNull { it.referencedAssetId } + doc.candidateAssetIds
        if (refIds.isNotEmpty()) {
            warmMediaPaths(refIds)
        }
        return doc
    }

    suspend fun saveMoodboard(document: MoodboardDocumentDto): MoodboardDocumentDto? {
        return runCatching { repository.saveBoard(document) }
            .onSuccess { reloadLibrary(quiet = true) }
            .getOrNull()
    }

    suspend fun solveEditorialLayout(
        document: MoodboardDocumentDto,
        containerWidth: Double
    ): EditorialLayoutResultDto? {
        return runCatching { repository.solveEditorialLayout(document, containerWidth) }.getOrNull()
    }

    suspend fun exportBoardPngFile(boardId: String, title: String): File? = withContext(Dispatchers.IO) {
        runCatching {
            val bytes = repository.exportBoardImageBytes(boardId)
            val safeName = title.replace(Regex("[^a-zA-Z0-9\\u4e00-\\u9fa5._-]"), "_").ifBlank { "moodboard" }
            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            File(dir, "${safeName}_${System.currentTimeMillis()}.png").apply { writeBytes(bytes) }
        }.getOrNull()
    }

    suspend fun exportBoardFigmaBridgeFile(
        boardId: String,
        title: String
    ): Pair<File, FigmaBridgeExportReportDto>? = withContext(Dispatchers.IO) {
        runCatching {
            val safeName = title.replace(Regex("[^a-zA-Z0-9\\u4e00-\\u9fa5._-]"), "_").ifBlank { "moodboard" }
            val dir = File(context.cacheDir, "exports").apply { mkdirs() }
            val outFile = File(dir, "${safeName}.charkleboard")
            val report = repository.exportBoardFigmaBridge(boardId, outFile.absolutePath)
            outFile to report
        }.getOrNull()
    }

    fun revealAssetFromMoodboard(assetId: String, sourceBoardId: String) {
        searchDebounceJob?.cancel()
        highlightJob?.cancel()
        _state.update {
            it.copy(
                activeMoodboardId = null,
                activeTab = PrimaryTab.Library,
                scope = LibraryScope.AllItems,
                inspectedAssetId = assetId,
                highlightedAssetId = assetId
            )
        }
        highlightJob = scope.launch {
            reloadAssetsNow()
            showToast(
                message = "已在素材库中定位素材",
                actionLabel = "返回情绪板",
                onAction = { openMoodboard(sourceBoardId) }
            )
            delay(3200)
            _state.update { if (it.highlightedAssetId == assetId) it.copy(highlightedAssetId = null) else it }
        }
    }

    suspend fun resolveOriginalFile(assetId: String): File? = withContext(Dispatchers.IO) {
        val cached = repository.cachedOriginalPathAsync(assetId)?.let(::File)?.takeIf { it.isFile }
        if (cached != null) {
            mediaPathCache.updateOriginalPath(assetId, cached.absolutePath)
            return@withContext cached
        }
        val downloaded = runCatching {
            val path = repository.originalPathOrDownload(assetId)
            File(path).takeIf { it.isFile }
        }.getOrNull()
        if (downloaded != null) {
            mediaPathCache.updateOriginalPath(assetId, downloaded.absolutePath)
            bumpMediaCacheRevision()
            return@withContext downloaded
        }
        warmMediaPaths(listOf(assetId))
        mediaPathCache.originalOrThumbPath(assetId)?.let(::File)
    }

    suspend fun runQuickJump(query: String): List<QuickJumpMatchDto> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return emptyList()
        return runCatching { repository.quickJump(trimmed, limit = 20) }.getOrDefault(emptyList())
    }

    suspend fun runLocalSemanticSearch(query: String): SemanticSearchReportDto? {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return null
        val criteria = buildEffectiveCriteria(_state.value.scope, _state.value.criteria)
        val report = runCatching { repository.semanticSearchLocal(trimmed, criteria, limit = 40) }.getOrNull()
        if (report != null && report.hits.isNotEmpty()) {
            warmMediaPaths(report.hits.map { it.asset.id })
        }
        return report
    }

    fun updateAssetDetails(
        assetId: String,
        title: String? = null,
        notes: String? = null,
        addTags: List<String> = emptyList(),
        removeTags: List<String> = emptyList()
    ) {
        scope.launch {
            runCatching {
                repository.updateAssets(
                    assetIds = listOf(assetId),
                    title = title,
                    notes = notes,
                    addTags = addTags,
                    removeTags = removeTags
                )
            }.onSuccess {
                reloadLibrary(quiet = true)
                showToast("已保存素材信息")
            }.onFailure {
                showToast("保存失败：${it.message}")
            }
        }
    }

    fun renameFolder(folderId: String, newName: String) {
        val clean = newName.trim()
        if (clean.isEmpty()) return
        scope.launch {
            runCatching { repository.renameFolder(folderId, clean) }
                .onSuccess {
                    reloadLibrary(quiet = true)
                    showToast("已重命名为「${it.name}」")
                }
                .onFailure { showToast("重命名失败：${it.message}") }
        }
    }

    fun updateFolderColor(folderId: String, colorHex: String?) {
        scope.launch {
            runCatching { repository.updateFolderAppearance(folderId, colorHex) }
                .onSuccess { reloadLibrary(quiet = true) }
        }
    }

    fun deleteFolder(folderId: String, trashContents: Boolean = false) {
        scope.launch {
            val affectedIds = collectFolderSubtreeIds(folderId, _state.value.folders)
            runCatching { repository.deleteFolder(folderId, trashContents) }
                .onSuccess {
                    val activeFolderId = (_state.value.scope as? LibraryScope.Folder)?.folderId
                    if (activeFolderId != null && normalizeUuidKey(activeFolderId) in affectedIds) {
                        _state.update {
                            it.copy(
                                scope = LibraryScope.AllItems,
                                isMultiSelectMode = false,
                                selectedAssetIds = emptySet()
                            )
                        }
                    }
                    reloadLibrary(quiet = true)
                    showToast("已移除文件夹")
                }
                .onFailure { showToast("删除文件夹失败：${it.message}") }
        }
    }

    fun upsertSyncBackend(profile: SyncBackendProfileDto, webdavPassword: String? = null) {
        scope.launch {
            val current = _state.value.syncConfig
            val list = current.backends.toMutableList()
            val idx = list.indexOfFirst { it.id == profile.id }
            if (idx >= 0) list[idx] = profile else list.add(profile)
            val nextMode = list.firstOrNull { it.isEnabled }?.mode ?: "localOnly"
            val updated = current.copy(mode = nextMode, backends = list)
            runCatching {
                repository.saveSyncConfig(updated)
                if (!webdavPassword.isNullOrBlank() && profile.mode == "webDAV") {
                    repository.saveBackendWebDavPassword(profile.id, webdavPassword)
                }
            }.onSuccess {
                loadSyncAndStorage()
                showToast("已保存同步后端「${profile.name}」")
            }.onFailure {
                showToast("保存后端失败：${it.message}")
            }
        }
    }

    fun removeSyncBackend(backendId: String) {
        scope.launch {
            val current = _state.value.syncConfig
            val nextList = current.backends.filterNot { it.id == backendId }
            val nextMode = nextList.firstOrNull { it.isEnabled }?.mode ?: "localOnly"
            runCatching { repository.saveSyncConfig(current.copy(mode = nextMode, backends = nextList)) }
                .onSuccess {
                    loadSyncAndStorage()
                    showToast("已移除同步后端")
                }
        }
    }

    suspend fun hasBackendWebDavPassword(backendId: String): Boolean {
        return runCatching { repository.hasBackendWebDavPassword(backendId) }.getOrDefault(false)
    }

    fun testSyncBackend(profile: SyncBackendProfileDto, webdavPassword: String? = null) {
        scope.launch {
            showToast("正在测试连接…")
            runCatching { repository.testBackendConnection(profile, webdavPassword) }
                .onSuccess { info ->
                    val label = info.displayName.ifBlank { info.email.ifBlank { info.source } }
                    showToast("连接成功：$label")
                }
                .onFailure {
                    showToast("连接失败：${it.message}")
                }
        }
    }

    fun importGoogleOAuthClientJson(uri: Uri) {
        scope.launch {
            val bytes = withContext(Dispatchers.IO) {
                runCatching {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                }.getOrNull()
            }
            if (bytes == null || bytes.isEmpty()) {
                showToast("无法读取凭据 JSON 文件")
                return@launch
            }
            runCatching { repository.importGoogleOAuthClientJson(bytes) }
                .onSuccess {
                    loadSyncAndStorage()
                    showToast("已导入 Google OAuth 凭据")
                }
                .onFailure { showToast("导入失败：${it.message}") }
        }
    }

    fun beginGoogleOAuthFlow(onLaunchUrl: (String) -> Unit) {
        scope.launch {
            runCatching {
                repository.prepareGooglePkceAuth(
                    redirectUri = "charkle-android://oauth/callback",
                    fullDriveScope = true
                )
            }.onSuccess { started ->
                val session = PendingPkceSession(
                    codeVerifier = started.codeVerifier,
                    state = started.state,
                    redirectUri = started.redirectUri,
                    expiresAtMs = System.currentTimeMillis() + PKCE_TTL_MS
                )
                pendingGooglePkce = session
                withContext(Dispatchers.IO) {
                    runCatching {
                        vault?.setSecret(PKCE_VAULT_KEY, pkceJson.encodeToString(session))
                    }
                }
                onLaunchUrl(started.authUrl)
            }.onFailure {
                showToast("启动 Google 登录失败：${it.message}")
            }
        }
    }

    fun handleOAuthRedirectUri(uri: Uri) {
        val code = uri.getQueryParameter("code")
        val returnedState = uri.getQueryParameter("state")
        val oauthError = uri.getQueryParameter("error")

        scope.launch {
            val session = pendingGooglePkce ?: withContext(Dispatchers.IO) {
                runCatching {
                    vault?.getSecret(PKCE_VAULT_KEY)?.let { raw ->
                        pkceJson.decodeFromString<PendingPkceSession>(raw)
                    }
                }.getOrNull()
            }

            when (
                val outcome = evaluateOAuthRedirect(
                    code = code,
                    returnedState = returnedState,
                    oauthError = oauthError,
                    session = session,
                    nowMs = System.currentTimeMillis()
                )
            ) {
                is OAuthRedirectResult.Failed -> {
                    if (outcome.clearSession) {
                        clearPendingPkceSession()
                    }
                    showToast(outcome.message)
                }
                is OAuthRedirectResult.Authorized -> {
                    clearPendingPkceSession()
                    runCatching {
                        repository.completeGooglePkceAuth(
                            code = outcome.code,
                            codeVerifier = outcome.session.codeVerifier,
                            redirectUri = outcome.session.redirectUri
                        )
                    }.onSuccess {
                        loadSyncAndStorage()
                        showToast("Google Drive 登录成功")
                        syncNow()
                    }.onFailure {
                        showToast("换取授权令牌失败：${it.message}")
                    }
                }
            }
        }
    }

    private suspend fun clearPendingPkceSession() {
        pendingGooglePkce = null
        withContext(Dispatchers.IO) {
            runCatching { vault?.deleteSecret(PKCE_VAULT_KEY) }
        }
    }

    fun signOutGoogle() {
        scope.launch {
            runCatching { repository.googleOAuthSignOut() }
                .onSuccess {
                    clearPendingPkceSession()
                    loadSyncAndStorage()
                    showToast("已退出 Google 账号")
                }
        }
    }

    fun updateBackgroundSyncIntervalMinutes(minutes: Long) {
        scope.launch {
            val updated = _state.value.syncConfig.copy(autoSyncIntervalSeconds = (minutes * 60L).toInt())
            runCatching { repository.saveSyncConfig(updated) }
            CharkleSyncWorker.schedule(context, minutes)
            loadSyncAndStorage()
            showToast(if (minutes <= 0L) "已切为手动同步" else "已设为每 $minutes 分钟后台增量同步")
        }
    }

    fun updateSyncFlags(syncThumbnails: Boolean? = null, syncEmbeddings: Boolean? = null) {
        scope.launch {
            val cur = _state.value.syncConfig
            val next = cur.copy(
                syncThumbnails = syncThumbnails ?: cur.syncThumbnails,
                syncEmbeddings = syncEmbeddings ?: cur.syncEmbeddings
            )
            runCatching { repository.saveSyncConfig(next) }
            loadSyncAndStorage()
        }
    }

    fun cycleColumnCount() {
        val next = when (_state.value.columnCount) {
            2 -> 3
            3 -> 4
            4 -> 1
            else -> 2
        }
        setColumnCount(next)
    }

    fun setAppearanceMode(mode: CharkleAppearanceMode) {
        prefs.edit().putInt("appearance_mode", mode.ordinal).apply()
        _state.update { it.copy(appearanceMode = mode) }
    }

    fun setFollowSystemAccent(enabled: Boolean) {
        prefs.edit().putBoolean("follow_system_accent", enabled).apply()
        _state.update { it.copy(followSystemAccentOnControls = enabled) }
    }

    fun setDefaultColorProofing(enabled: Boolean) {
        prefs.edit().putBoolean("default_color_proofing", enabled).apply()
        _state.update { it.copy(defaultColorProofing = enabled) }
    }

    fun toggleMultiSelect(enabled: Boolean) {
        _state.update {
            it.copy(
                isMultiSelectMode = enabled,
                selectedAssetIds = if (enabled) it.selectedAssetIds else emptySet()
            )
        }
    }

    fun toggleAssetSelection(assetId: String) {
        _state.update { current ->
            val next = if (assetId in current.selectedAssetIds) {
                current.selectedAssetIds - assetId
            } else {
                current.selectedAssetIds + assetId
            }
            current.copy(
                isMultiSelectMode = next.isNotEmpty() || current.isMultiSelectMode,
                selectedAssetIds = next
            )
        }
    }

    /**
     * Pure lock-free in-memory lookup safe to invoke during Compose composition (zero FFI or disk I/O).
     * Cache misses schedule an asynchronous batched background prefetch and update `mediaCacheRevision`.
     */
    fun thumbnailFile(assetId: String, previewTier: Boolean = false): File? {
        if (!mediaPathCache.contains(assetId)) {
            enqueueMediaPathPrefetch(assetId)
            return null
        }
        return mediaPathCache.thumbnailPath(assetId, previewTier)?.let(::File)
    }

    /**
     * Pure lock-free in-memory lookup safe to invoke during Compose composition (zero FFI or disk I/O).
     */
    fun originalOrThumbFile(assetId: String): File? {
        if (!mediaPathCache.contains(assetId)) {
            enqueueMediaPathPrefetch(assetId)
            return null
        }
        return mediaPathCache.originalOrThumbPath(assetId)?.let(::File)
    }

    suspend fun prefetchMediaPaths(assetIds: Collection<String>) {
        if (assetIds.isEmpty()) return
        warmMediaPaths(assetIds)
        bumpMediaCacheRevision()
    }

    private fun enqueueMediaPathPrefetch(assetId: String) {
        val key = normalizeUuidKey(assetId)
        if (key.isEmpty()) return
        pendingPrefetchIds.add(key)
        if (mediaPrefetchJob?.isActive == true) return
        mediaPrefetchJob = scope.launch {
            delay(16)
            val batch = mutableListOf<String>()
            val iterator = pendingPrefetchIds.iterator()
            while (iterator.hasNext()) {
                val item = iterator.next()
                iterator.remove()
                batch.add(item)
            }
            if (batch.isNotEmpty()) {
                warmMediaPaths(batch)
                bumpMediaCacheRevision()
            }
        }
    }

    private suspend fun warmMediaPaths(assetIds: Collection<String>) {
        val unique = assetIds
            .map(::normalizeUuidKey)
            .filter { it.isNotEmpty() }
            .distinct()
        if (unique.isEmpty()) return
        val resolved = runCatching { repository.resolveMediaPaths(unique) }.getOrNull() ?: return
        mediaPathCache.markResolvedEmpty(unique, resolved)
    }

    private fun bumpMediaCacheRevision() {
        _state.update { it.copy(mediaCacheRevision = it.mediaCacheRevision + 1L) }
    }

    suspend fun loadFolderSuggestion(assetId: String): FolderSuggestionDto? {
        return runCatching { repository.suggestFolder(assetId) }.getOrNull()
    }

    suspend fun loadSimilarAssets(assetId: String): List<ScoredAssetDto> {
        val items = runCatching { repository.similarAssets(assetId, limit = 12) }.getOrDefault(emptyList())
        if (items.isNotEmpty()) {
            warmMediaPaths(items.map { it.asset.id })
        }
        return items
    }

    fun markOpened(assetId: String) {
        scope.launch { runCatching { repository.markAssetOpened(assetId) } }
    }

    fun setAssetRating(assetId: String, rating: Int) {
        scope.launch {
            runCatching { repository.updateAssets(listOf(assetId), rating = rating) }
                .onSuccess {
                    reloadLibrary(quiet = true)
                    showToast(if (rating > 0) "已评为 $rating 星" else "已清除星标")
                }
                .onFailure { showToast("更新评分失败：${it.message}") }
        }
    }

    fun toggleOfflinePin(asset: AssetDto) {
        val next = !asset.pinnedOffline
        scope.launch {
            runCatching { repository.updateAssets(listOf(asset.id), pinnedOffline = next) }
                .onSuccess {
                    reloadLibrary(quiet = true)
                    loadSyncAndStorage()
                    showToast(if (next) "已置顶离线原图" else "已取消离线置顶")
                }
        }
    }

    fun moveAssetsToFolder(assetIds: List<String>, folderId: String?, folderName: String? = null) {
        if (assetIds.isEmpty()) return
        scope.launch {
            runCatching {
                repository.updateAssets(
                    assetIds = assetIds,
                    folderId = folderId,
                    moveToInbox = folderId == null
                )
            }.onSuccess {
                _state.update { it.copy(isMultiSelectMode = false, selectedAssetIds = emptySet()) }
                reloadLibrary(quiet = true)
                val dest = folderName ?: if (folderId == null) "收件箱" else "目标文件夹"
                showToast("已归入「$dest」")
            }.onFailure {
                showToast("移动失败：${it.message}")
            }
        }
    }

    fun trashAssets(assetIds: List<String>) {
        if (assetIds.isEmpty()) return
        scope.launch {
            runCatching { repository.updateAssets(assetIds = assetIds, isTrashed = true) }
                .onSuccess {
                    _state.update { it.copy(isMultiSelectMode = false, selectedAssetIds = emptySet()) }
                    reloadLibrary(quiet = true)
                    showToast(
                        message = "已移至回收站（${assetIds.size} 项）",
                        actionLabel = "撤销",
                        onAction = { restoreAssets(assetIds) }
                    )
                }
        }
    }

    fun restoreAssets(assetIds: List<String>) {
        if (assetIds.isEmpty()) return
        scope.launch {
            runCatching { repository.updateAssets(assetIds = assetIds, isTrashed = false) }
                .onSuccess {
                    reloadLibrary(quiet = true)
                    showToast("已恢复 ${assetIds.size} 项素材")
                }
        }
    }

    fun updateAssetNotesAndTags(assetId: String, notes: String, addTags: List<String>, removeTags: List<String>) {
        scope.launch {
            runCatching {
                repository.updateAssets(
                    assetIds = listOf(assetId),
                    notes = notes,
                    addTags = addTags,
                    removeTags = removeTags
                )
            }.onSuccess {
                reloadLibrary(quiet = true)
                showToast("已保存素材信息")
            }
        }
    }

    fun createFolder(name: String, parentId: String? = null) {
        val clean = name.trim()
        if (clean.isEmpty()) return
        scope.launch {
            runCatching { repository.createFolder(clean, parentId) }
                .onSuccess {
                    reloadLibrary(quiet = true)
                    showToast("已创建文件夹「${it.name}」")
                }
                .onFailure { showToast("创建失败：${it.message}") }
        }
    }

    fun ingestWebUrl(
        rawText: String,
        targetFolderId: String? = null,
        title: String? = null,
        notes: String? = null,
        onError: (String) -> Unit = {},
        onDone: () -> Unit = {}
    ) {
        val cleaned = rawText.trim()
        if (cleaned.isEmpty()) {
            val msg = "请输入或粘贴有效的网页链接"
            onError(msg)
            showToast(msg)
            return
        }
        scope.launch {
            beginIngest()
            try {
                val imported = repository.ingestWebUrl(
                    url = cleaned,
                    title = title,
                    notes = notes,
                    targetFolderId = targetFolderId
                )
                warmMediaPaths(imported.map { it.id })
                reloadLibrary(quiet = true)
                showToast("已收藏 ${imported.size} 项网页/灵感")
                onDone()
            } catch (ce: CancellationException) {
                throw ce
            } catch (t: Throwable) {
                val msg = "采集链接失败：${t.message ?: "请检查网络或链接格式"}"
                showToast(msg)
                onError(msg)
            } finally {
                endIngest()
            }
        }
    }

    fun ingestContentUris(
        uris: List<Uri>,
        targetFolderId: String? = null,
        onError: (String) -> Unit = {},
        onDone: () -> Unit = {}
    ) {
        if (uris.isEmpty()) {
            val msg = "未选择可导入的文件"
            onError(msg)
            return
        }
        scope.launch {
            beginIngest()
            try {
                val result = withContext(Dispatchers.IO) {
                    val stagingDir = File(context.cacheDir, "ingest-staging").apply { mkdirs() }
                    val createdFiles = mutableListOf<File>()
                    val stagedPaths = mutableListOf<String>()
                    try {
                        for (uri in uris) {
                            val displayName = resolveDisplayName(uri)
                            val mime = runCatching { context.contentResolver.getType(uri) }.getOrNull()
                            val ext = mime?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
                            val safeName = sanitizeStagedFileName(displayName, ext)
                            val dst = File(stagingDir, "${System.nanoTime()}_$safeName")
                            createdFiles.add(dst)
                            runCatching {
                                context.contentResolver.openInputStream(uri)?.use { input ->
                                    dst.outputStream().use { output -> input.copyTo(output) }
                                }
                                if (dst.isFile && dst.length() > 0L) {
                                    stagedPaths.add(dst.absolutePath)
                                }
                            }
                        }
                        if (stagedPaths.isEmpty()) {
                            Result.failure(IllegalStateException("未能读取所选文件"))
                        } else {
                            runCatching {
                                repository.ingestLocalFiles(stagedPaths, targetFolderId = targetFolderId)
                            }
                        }
                    } finally {
                        withContext(NonCancellable) {
                            createdFiles.forEach { file ->
                                runCatching { if (file.exists()) file.delete() }
                            }
                        }
                    }
                }
                result.onSuccess { imported ->
                    if (imported.isNotEmpty()) {
                        warmMediaPaths(imported.map { it.id })
                        reloadLibrary(quiet = true)
                        loadSyncAndStorage()
                        showToast("已收藏 ${imported.size} 项素材")
                        onDone()
                    } else {
                        val msg = "未能导入所选文件"
                        showToast(msg)
                        onError(msg)
                    }
                }.onFailure { err ->
                    val msg = err.message?.takeIf { it.isNotBlank() } ?: "未能读取所选文件"
                    showToast(msg)
                    onError(msg)
                }
            } finally {
                endIngest()
            }
        }
    }

    private fun beginIngest() {
        if (activeIngestCount.incrementAndGet() > 0) {
            _state.update { it.copy(isIngesting = true) }
        }
    }

    private fun endIngest() {
        if (activeIngestCount.decrementAndGet().coerceAtLeast(0) == 0) {
            activeIngestCount.set(0)
            _state.update { it.copy(isIngesting = false) }
        }
    }

    fun syncNow() {
        if (!syncInFlight.compareAndSet(false, true)) return
        scope.launch {
            _state.update { it.copy(isSyncing = true) }
            try {
                runCatching { repository.syncNow() }
                    .onSuccess { report ->
                        reloadLibrary(quiet = true)
                        loadSyncAndStorage()
                        val discovered = if (report.discoveredRemoteAssets > 0) {
                            " · 新发现 ${report.discoveredRemoteAssets} 项"
                        } else {
                            ""
                        }
                        showToast("同步完成：拉取 ${report.pulledOps} / 上传 ${report.pushedOps}$discovered")
                    }
                    .onFailure {
                        showToast("同步提示：${it.message ?: "请先配置云盘后端"}")
                    }
            } finally {
                syncInFlight.set(false)
                _state.update { it.copy(isSyncing = false) }
            }
        }
    }

    fun saveGoogleClientId(clientId: String) {
        scope.launch {
            runCatching { repository.saveGoogleOAuthClientId(clientId) }
                .onSuccess {
                    loadSyncAndStorage()
                    showToast("已保存 Google OAuth 凭据")
                }
                .onFailure { showToast("保存失败：${it.message}") }
        }
    }

    fun setCacheBudgetGb(gb: Double) {
        scope.launch {
            val bytes = (gb * 1024.0 * 1024.0 * 1024.0).toLong()
            runCatching { repository.setCacheBudgetBytes(bytes) }
                .onSuccess { appliedBytes ->
                    val appliedGb = appliedBytes / (1024.0 * 1024.0 * 1024.0)
                    mediaPathCache.clearOriginalPaths()
                    val activeIds = (_state.value.assets + _state.value.inboxAssets).map { it.id }
                    warmMediaPaths(activeIds)
                    bumpMediaCacheRevision()
                    loadSyncAndStorage()
                    showToast("原图缓存上限已设为 ${String.format(Locale.ROOT, "%.0f", appliedGb)} GB")
                }
                .onFailure { showToast("更新缓存上限失败：${it.message}") }
        }
    }

    fun evictCacheNow() {
        scope.launch {
            runCatching { repository.evictCacheNow() }
                .onSuccess { stats ->
                    mediaPathCache.clearOriginalPaths()
                    val activeIds = (_state.value.assets + _state.value.inboxAssets).map { it.id }
                    warmMediaPaths(activeIds)
                    _state.update {
                        it.copy(
                            cacheStats = stats,
                            mediaCacheRevision = it.mediaCacheRevision + 1L
                        )
                    }
                    showToast("已清理可回收原图缓存")
                }
        }
    }

    fun showToast(message: String, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
        toastJob?.cancel()
        val toast = AppToast(message = message, actionLabel = actionLabel, onAction = onAction)
        _state.update { it.copy(toast = toast) }
        toastJob = scope.launch {
            delay(if (actionLabel != null) 4800 else 3000)
            _state.update { if (it.toast?.id == toast.id) it.copy(toast = null) else it }
        }
    }

    fun dismissToast() {
        toastJob?.cancel()
        _state.update { it.copy(toast = null) }
    }

    fun reloadLibrary(quiet: Boolean = false) {
        val gen = libraryGeneration.incrementAndGet()
        val assetsGen = assetsGeneration.incrementAndGet()
        val inboxGen = inboxGeneration.incrementAndGet()
        libraryLoadJob?.cancel()
        assetsLoadJob?.cancel()
        inboxLoadJob?.cancel()

        libraryLoadJob = scope.launch {
            if (!quiet) _state.update { it.copy(isLoading = true) }
            try {
                val snapshotScope = _state.value.scope
                val snapshotCriteria = _state.value.criteria

                val (folders, smartFolders, boards, tags, assets, inboxAssets) = coroutineScope {
                    val fDef = async { runCatching { repository.fetchFolders() }.getOrDefault(emptyList()) }
                    val sfDef = async { runCatching { repository.fetchSmartFolders() }.getOrDefault(emptyList()) }
                    val bDef = async { runCatching { repository.fetchBoards() }.getOrDefault(emptyList()) }
                    val tDef = async { runCatching { repository.fetchTagCounts() }.getOrDefault(emptyList()) }
                    val aDef = async { fetchAssetsForScope(snapshotScope, snapshotCriteria) }
                    val iDef = async {
                        runCatching {
                            repository.fetchAssets(FilterCriteriaDto(onlyInbox = true, includeSubfolders = false))
                        }.getOrDefault(emptyList())
                    }
                    LibraryReloadSnapshot(
                        folders = fDef.await(),
                        smartFolders = sfDef.await(),
                        boards = bDef.await(),
                        tagCounts = tDef.await(),
                        assets = aDef.await(),
                        inboxAssets = iDef.await()
                    )
                }

                if (gen != libraryGeneration.get()) return@launch

                val idsToWarm = buildList(assets.size + inboxAssets.size + boards.size * 4) {
                    assets.forEach { add(it.id) }
                    inboxAssets.forEach { add(it.id) }
                    boards.forEach { board -> addAll(board.previewAssetIDs) }
                }
                warmMediaPaths(idsToWarm)

                if (gen != libraryGeneration.get()) return@launch

                _state.update { current ->
                    current.copy(
                        folders = folders,
                        smartFolders = smartFolders,
                        boards = boards,
                        tagCounts = tags,
                        assets = if (assetsGen == assetsGeneration.get()) assets else current.assets,
                        inboxAssets = if (inboxGen == inboxGeneration.get()) inboxAssets else current.inboxAssets,
                        inboxCount = if (inboxGen == inboxGeneration.get()) inboxAssets.size else current.inboxCount,
                        mediaCacheRevision = current.mediaCacheRevision + 1L,
                        isLoading = false
                    )
                }
                scheduleWidgetRefresh()
            } catch (ce: CancellationException) {
                throw ce
            } finally {
                if (gen == libraryGeneration.get() && _state.value.isLoading) {
                    _state.update { it.copy(isLoading = false) }
                }
            }
        }
    }

    private fun scheduleAssetsReload() {
        assetsLoadJob?.cancel()
        assetsLoadJob = scope.launch {
            reloadAssetsNow()
        }
    }

    private suspend fun reloadAssetsNow() {
        val gen = assetsGeneration.incrementAndGet()
        val snapshotScope = _state.value.scope
        val snapshotCriteria = _state.value.criteria
        val fetched = fetchAssetsForScope(snapshotScope, snapshotCriteria)
        if (gen != assetsGeneration.get()) return
        warmMediaPaths(fetched.map { it.id })
        if (gen != assetsGeneration.get()) return
        _state.update {
            it.copy(
                assets = fetched,
                mediaCacheRevision = it.mediaCacheRevision + 1L
            )
        }
    }

    private suspend fun fetchAssetsForScope(
        targetScope: LibraryScope,
        baseCriteria: FilterCriteriaDto
    ): List<AssetDto> {
        val effectiveCriteria = buildEffectiveCriteria(targetScope, baseCriteria)
        return runCatching {
            when (targetScope) {
                is LibraryScope.SmartFolder -> repository.fetchSmartFolderAssets(
                    smartFolderId = targetScope.smartFolderId,
                    criteria = effectiveCriteria
                )
                else -> repository.fetchAssets(effectiveCriteria)
            }
        }.getOrDefault(emptyList())
    }

    private fun scheduleInboxReload() {
        inboxLoadJob?.cancel()
        inboxLoadJob = scope.launch {
            val gen = inboxGeneration.incrementAndGet()
            val inboxCriteria = FilterCriteriaDto(onlyInbox = true, includeSubfolders = false)
            val fetched = runCatching { repository.fetchAssets(inboxCriteria) }.getOrDefault(emptyList())
            if (gen != inboxGeneration.get()) return@launch
            warmMediaPaths(fetched.map { it.id })
            if (gen != inboxGeneration.get()) return@launch
            _state.update {
                it.copy(
                    inboxAssets = fetched,
                    inboxCount = fetched.size,
                    mediaCacheRevision = it.mediaCacheRevision + 1L
                )
            }
        }
    }

    private suspend fun loadSyncAndStorage() {
        val (cfg, st, stats, hasOAuth) = coroutineScope {
            val cfgDef = async { runCatching { repository.syncConfig() }.getOrDefault(DriveSyncConfigDto()) }
            val stDef = async { runCatching { repository.syncStatus() }.getOrDefault(SyncStatusDto()) }
            val statsDef = async { runCatching { repository.cacheStats() }.getOrDefault(CacheStatsDto()) }
            val oauthDef = async { runCatching { repository.hasGoogleOAuthClient() }.getOrDefault(false) }
            SyncAndStorageSnapshot(cfgDef.await(), stDef.await(), statsDef.await(), oauthDef.await())
        }
        _state.update {
            it.copy(
                syncConfig = cfg,
                syncStatus = st,
                cacheStats = stats,
                hasGoogleOAuthClient = hasOAuth
            )
        }
    }

    private fun resolveDisplayName(uri: Uri): String? {
        return runCatching {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        }.getOrNull()
    }

    private data class LibraryReloadSnapshot(
        val folders: List<FolderDto>,
        val smartFolders: List<SmartFolderDto>,
        val boards: List<MoodboardSummaryDto>,
        val tagCounts: List<TagCountDto>,
        val assets: List<AssetDto>,
        val inboxAssets: List<AssetDto>
    )

    private data class SyncAndStorageSnapshot(
        val config: DriveSyncConfigDto,
        val status: SyncStatusDto,
        val cacheStats: CacheStatsDto,
        val hasGoogleOAuthClient: Boolean
    )

    companion object {
        private const val PKCE_VAULT_KEY = "android.oauth.pending_pkce_v1"
        private const val PKCE_TTL_MS = 15L * 60L * 1000L
    }
}

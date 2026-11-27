package com.charkle.android.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

@Serializable
data class LabColorDto(
    val hex: String,
    val l: Double = 50.0,
    val a: Double = 0.0,
    val b: Double = 0.0,
    val proportion: Double = 1.0
)

@Serializable
data class PhotoExifDto(
    val cameraMake: String? = null,
    val cameraModel: String? = null,
    val lensModel: String? = null,
    val capturedAt: String? = null,
    @SerialName("exposureTime") val exposureTime: String? = null,
    @SerialName("fNumber") val apertureFNumber: Double? = null,
    @SerialName("iso") val isoSpeed: Int? = null,
    @SerialName("focalLengthMM") val focalLengthMm: Double? = null,
    val focalLength35mm: Int? = null,
    @SerialName("colorProfile") val colorSpace: String? = null
) {
    val hasMeaningfulCameraInfo: Boolean
        get() = !cameraMake.isNullOrBlank() ||
            !cameraModel.isNullOrBlank() ||
            !lensModel.isNullOrBlank() ||
            !capturedAt.isNullOrBlank() ||
            !exposureTime.isNullOrBlank() ||
            focalLengthMm != null ||
            apertureFNumber != null ||
            isoSpeed != null
}

@Serializable
data class AiGenerationDto(
    val generator: String? = null,
    val prompt: String? = null,
    val negativePrompt: String? = null,
    val modelName: String? = null,
    val sampler: String? = null,
    val steps: Int? = null,
    val cfgScale: Double? = null,
    val seed: String? = null,
    val loras: List<String> = emptyList()
) {
    val hasContent: Boolean
        get() = !prompt.isNullOrBlank() || !modelName.isNullOrBlank() || !generator.isNullOrBlank()
}

@Serializable
data class SocialPostDto(
    val platform: String = "x",
    val authorName: String? = null,
    val authorHandle: String? = null,
    @SerialName("authorAvatarURL") val authorAvatarUrl: String? = null,
    val publishedAtText: String? = null,
    @SerialName("bodyText") val text: String? = null,
    val quotedAuthor: String? = null,
    val quotedText: String? = null,
    val articleTitle: String? = null,
    val likeCount: Long? = null,
    @SerialName("originalURL") val originalUrl: String? = null,
    val videoDurationSeconds: Double? = null,
    val videoSummary: String? = null
)

@Serializable
data class GitHubRepoDto(
    val owner: String = "",
    val repo: String = "",
    val fullName: String = "",
    val description: String? = null,
    val stars: Long? = null,
    val forks: Long? = null,
    val language: String? = null,
    val topics: List<String> = emptyList(),
    @SerialName("homepageURL") val homepageUrl: String? = null
)

@Serializable
data class WebPageRichMetadataDto(
    val siteName: String? = null,
    val authorName: String? = null,
    val publishedAtText: String? = null,
    val summary: String? = null,
    val hasVideo: Boolean = false,
    val durationSeconds: Double? = null,
    @SerialName("canonicalURL") val canonicalUrl: String? = null
)

@Serializable
data class AssetRichMetadataDto(
    val githubRepo: GitHubRepoDto? = null,
    val socialPost: SocialPostDto? = null,
    val webPage: WebPageRichMetadataDto? = null,
    val photoExif: PhotoExifDto? = null,
    val aiGeneration: AiGenerationDto? = null,
    val textExcerpt: String? = null,
    val isMarkdown: Boolean = false,
    val model3DFormat: String? = null
)

@Serializable
data class AssetDto(
    val id: String,
    val title: String,
    val fileName: String = "",
    @SerialName("folderID") val folderId: String? = null,
    @SerialName("driveFileID") val driveFileId: String? = null,
    val contentHash: String = "",
    val mediaKind: String = "image",
    val mimeType: String = "image/jpeg",
    val fileSizeBytes: Long = 0,
    val pixelWidth: Int = 1200,
    val pixelHeight: Int = 900,
    val durationSeconds: Double? = null,
    val waveformPeaks: List<Float> = emptyList(),
    @SerialName("sourceURL") val sourceUrl: String? = null,
    val sourceDomain: String? = null,
    val notes: String = "",
    val tags: List<String> = emptyList(),
    val suggestedTags: List<String> = emptyList(),
    val aiDescription: String? = null,
    val ocrText: String? = null,
    val dominantColors: List<LabColorDto> = emptyList(),
    val rating: Int = 0,
    val pinnedOffline: Boolean = false,
    val isLocalOriginalCached: Boolean = false,
    val isTrashed: Boolean = false,
    val createdAt: Double = 0.0,
    val updatedAt: Double = 0.0,
    @SerialName("updatedHLC") val updatedHlc: Long = 0L,
    val lastOpenedAt: Double? = null,
    val richMetadata: AssetRichMetadataDto? = null
) {
    val aspectRatio: Float
        get() = if (pixelWidth > 0 && pixelHeight > 0) {
            (pixelWidth.toFloat() / pixelHeight.toFloat()).coerceIn(0.45f, 2.4f)
        } else {
            1.0f
        }

    val isInInbox: Boolean
        get() = folderId == null && !isTrashed

    val primarySwatchHex: String?
        get() = dominantColors.firstOrNull()?.hex

    val displayTypeLabel: String
        get() = when {
            richMetadata?.socialPost != null -> when (richMetadata.socialPost.platform.lowercase()) {
                "xiaohongshu" -> "小红书 笔记"
                "x" -> "X 推文"
                "threads" -> "Threads 贴文"
                "bluesky" -> "Bluesky 贴文"
                "pixiv" -> "Pixiv 作品"
                "instagram" -> "Instagram 贴文"
                "youtube" -> "YouTube 视频"
                "bilibili" -> "B站 视频"
                else -> "社媒收藏"
            }
            richMetadata?.githubRepo != null -> "GitHub 仓库"
            else -> when (mediaKind) {
                "image" -> "图片"
                "animatedImage" -> "动图"
                "video" -> "视频"
                "webBookmark" -> "网页"
                "document" -> "文档"
                "designFile" -> "设计文件"
                "audio" -> "音频"
                "model3D" -> "3D 模型"
                else -> "素材"
            }
        }
}

@Serializable
data class FolderDto(
    val id: String,
    val name: String,
    @SerialName("parentID") val parentId: String? = null,
    @SerialName("driveFolderID") val driveFolderId: String? = null,
    val colorHex: String? = null,
    val customSymbol: String? = null,
    val sortOrder: Int = 0,
    val assetCount: Int = 0
)

@Serializable
data class SmartFolderRuleDto(
    val matchMode: String = "all",
    val tags: List<String> = emptyList(),
    val descriptionQuery: String = "",
    val colorHexes: List<String> = emptyList(),
    val colorTolerance: Double = 24.0,
    val mediaKinds: List<String> = emptyList(),
    val minRating: Int = 0
)

@Serializable
data class SmartFolderDto(
    val id: String,
    val name: String,
    val colorHex: String? = null,
    val rule: SmartFolderRuleDto = SmartFolderRuleDto(),
    val sortOrder: Int = 0
)

@Serializable
data class TagCountDto(
    @SerialName("name") val tag: String,
    val count: Int = 0
)

@Serializable
data class CachedMediaPathsDto(
    val gridThumbPath: String? = null,
    val previewThumbPath: String? = null,
    val originalPath: String? = null
)

@Serializable
data class EngineEventEnvelope(
    val type: String,
    val payload: JsonElement? = null
)

@Serializable
data class MoodboardSummaryDto(
    val id: String,
    val title: String,
    val subtitle: String = "",
    val mode: BoardLayoutModeDto = BoardLayoutModeDto.freeform(),
    val itemCount: Int = 0,
    val previewAssetIDs: List<String> = emptyList(),
    val paletteHexes: List<String> = emptyList(),
    val pinnedOffline: Boolean = false,
    val updatedAt: Double = 0.0
)

fun cocoaNowSeconds(): Double = (System.currentTimeMillis() / 1000.0) - 978307200.0

@Serializable
class EmptyWireObj {
    override fun equals(other: Any?): Boolean = other is EmptyWireObj
    override fun hashCode(): Int = 0
}

@Serializable
data class BoardPointDto(
    val x: Double = 0.0,
    val y: Double = 0.0
)

@Serializable
data class BoardRectDto(
    val x: Double = 0.0,
    val y: Double = 0.0,
    val width: Double = 240.0,
    val height: Double = 240.0
)

@Serializable
data class NormalizedCropRectDto(
    val x: Double = 0.0,
    val y: Double = 0.0,
    val width: Double = 1.0,
    val height: Double = 1.0
)

@Serializable
data class AutoLayoutConfigDto(
    val columns: Int = 2,
    val spacing: Double = 14.0,
    val style: String = "balanced",
    val showPaletteStrip: Boolean = true
)

@Serializable
data class AutoEditorialWrapperDto(
    @SerialName("_0") val inner: AutoLayoutConfigDto = AutoLayoutConfigDto()
)

@Serializable
data class BoardLayoutModeDto(
    val freeform: EmptyWireObj? = null,
    val autoEditorial: AutoEditorialWrapperDto? = null
) {
    val isAutoEditorial: Boolean get() = autoEditorial != null
    val editorialConfig: AutoLayoutConfigDto? get() = autoEditorial?.inner

    companion object {
        fun freeform(): BoardLayoutModeDto = BoardLayoutModeDto(freeform = EmptyWireObj(), autoEditorial = null)
        fun autoEditorial(config: AutoLayoutConfigDto = AutoLayoutConfigDto()): BoardLayoutModeDto =
            BoardLayoutModeDto(freeform = null, autoEditorial = AutoEditorialWrapperDto(config))
    }
}

@Serializable
data class AssetRefNodeDto(
    @SerialName("assetID") val assetId: String,
    val crop: NormalizedCropRectDto? = null,
    val weight: Int = 1,
    val autoplayLoop: Boolean = false
)

@Serializable
data class NoteNodeDto(
    val title: String? = null,
    val text: String = "",
    val style: String = "warm",
    val fontSize: Double = 14.0
)

@Serializable
data class GroupFrameNodeDto(
    val title: String = "",
    val tint: String = "neutral"
)

@Serializable
data class PaletteStripNodeDto(
    val colors: List<LabColorDto> = emptyList(),
    val autoSyncWithBoard: Boolean = true
)

@Serializable
data class BoardNodeKindDto(
    val assetRef: AssetRefNodeDto? = null,
    val note: NoteNodeDto? = null,
    val groupFrame: GroupFrameNodeDto? = null,
    val paletteStrip: PaletteStripNodeDto? = null
)

@Serializable
data class BoardNodeDto(
    val id: String,
    val kind: BoardNodeKindDto,
    val frame: BoardRectDto = BoardRectDto(),
    val zIndex: Int = 0,
    val rotationDegrees: Double = 0.0,
    val flipHorizontal: Boolean = false,
    val flipVertical: Boolean = false,
    val isLocked: Boolean = false,
    val editorialOrder: Int = 0,
    val updatedAt: Double = cocoaNowSeconds()
) {
    val referencedAssetId: String? get() = kind.assetRef?.assetId
}

@Serializable
data class BoardConnectorDto(
    val id: String,
    @SerialName("fromNodeID") val fromNodeId: String,
    val fromAnchor: String = "auto",
    val fromNormalizedPoint: BoardPointDto? = null,
    @SerialName("toNodeID") val toNodeId: String,
    val toAnchor: String = "auto",
    val toNormalizedPoint: BoardPointDto? = null,
    val label: String? = null,
    val colorHex: String = "#5C6672",
    val style: String = "curved",
    val dashed: Boolean = false,
    val updatedAt: Double = cocoaNowSeconds()
)

@Serializable
data class InkStrokePointDto(
    val x: Double,
    val y: Double,
    val pressure: Double = 0.5
)

@Serializable
data class InkStrokeDto(
    val id: String,
    val points: List<InkStrokePointDto> = emptyList(),
    val colorHex: String = "#2A60E0",
    val lineWidth: Double = 3.5,
    val opacity: Double = 0.92,
    val zIndex: Int = 1000,
    val createdAt: Double = cocoaNowSeconds()
)

@Serializable
data class MoodboardDocumentDto(
    val id: String,
    val title: String,
    val subtitle: String = "",
    val mode: BoardLayoutModeDto = BoardLayoutModeDto.freeform(),
    val nodes: List<BoardNodeDto> = emptyList(),
    val connectors: List<BoardConnectorDto> = emptyList(),
    val inkStrokes: List<InkStrokeDto> = emptyList(),
    val extractedPalette: List<LabColorDto> = emptyList(),
    @SerialName("candidateAssetIDs") val candidateAssetIds: List<String> = emptyList(),
    val pinnedOffline: Boolean = false,
    val viewportCenter: BoardPointDto = BoardPointDto(),
    val viewportZoom: Double = 1.0,
    val createdAt: Double = cocoaNowSeconds(),
    val updatedAt: Double = cocoaNowSeconds(),
    @SerialName("updatedHLC") val updatedHlc: Long = 0L
)

@Serializable
data class EditorialSizeDto(
    val width: Double = 0.0,
    val height: Double = 0.0
)

@Serializable
data class EditorialLayoutResultDto(
    val frames: Map<String, BoardRectDto> = emptyMap(),
    val orderedNodeIds: List<String> = emptyList(),
    val contentSize: EditorialSizeDto = EditorialSizeDto(),
    val columnWidth: Double = 240.0,
    val columnCount: Int = 2
)

@Serializable
data class FigmaBridgeExportReportDto(
    val objectCount: Int = 0,
    val imageCount: Int = 0,
    val noteCount: Int = 0,
    val groupCount: Int = 0,
    val paletteCount: Int = 0,
    val connectorCount: Int = 0,
    val strokeCount: Int = 0,
    val reviewCount: Int = 0,
    val bundlePath: String = ""
)

// =========================================================================
// Pinterest Spatial Exploration Models
// =========================================================================

@Serializable
data class PinterestAccountDto(
    val id: String = "",
    val username: String = "",
    val fullName: String = "",
    @SerialName("avatarURL") val avatarUrl: String? = null,
    val email: String? = null
) {
    val displayName: String
        get() = fullName.trim().ifEmpty {
            username.trim().takeIf { it.isNotEmpty() }?.let { "@$it" } ?: "Pinterest 账号"
        }
}

@Serializable
data class PinterestBoardDto(
    val id: String,
    val name: String,
    val urlPath: String = "/",
    val description: String? = null,
    val pinCount: Long = 0L,
    @SerialName("coverImageURL") val coverImageUrl: String? = null,
    val isSecret: Boolean = false,
    val ownerUsername: String? = null
)

@Serializable
data class PinterestPinDto(
    val id: String,
    val title: String = "",
    val description: String = "",
    val authorName: String? = null,
    val authorUsername: String? = null,
    @SerialName("authorAvatarURL") val authorAvatarUrl: String? = null,
    val boardName: String? = null,
    @SerialName("boardID") val boardId: String? = null,
    val domain: String? = null,
    @SerialName("linkURL") val linkUrl: String? = null,
    @SerialName("pinPageURL") val pinPageUrl: String = "",
    @SerialName("originalURL") val originalUrl: String? = null,
    @SerialName("previewURL") val previewUrl: String? = null,
    @SerialName("thumbnailURL") val thumbnailUrl: String? = null,
    @SerialName("videoURL") val videoUrl: String? = null,
    val pixelWidth: Int = 0,
    val pixelHeight: Int = 0,
    val dominantColorHex: String? = null
) {
    val displayTitle: String
        get() = title.trim().ifEmpty {
            description.trim().take(72).ifEmpty {
                boardName?.trim()?.takeIf { it.isNotEmpty() } ?: "Pinterest $id"
            }
        }

    fun bestDisplayUrl(large: Boolean = false): String? =
        if (large) originalUrl ?: previewUrl ?: thumbnailUrl
        else previewUrl ?: originalUrl ?: thumbnailUrl
}

@Serializable
data class PinterestFeedPageDto(
    val pins: List<PinterestPinDto> = emptyList(),
    val nextBookmark: String? = null,
    val hasMore: Boolean = false,
    val sourceDescription: String = ""
)

@Serializable
data class PinterestPinDetailResultDto(
    val pin: PinterestPinDto,
    val similarPins: List<PinterestPinDto> = emptyList(),
    val nextSimilarBookmark: String? = null,
    val hasMoreSimilar: Boolean = false
)

@Serializable
data class SpatialRectDto(
    val x: Double = 0.0,
    val y: Double = 0.0,
    val width: Double = 224.0,
    val height: Double = 280.0
)

@Serializable
data class PinterestSpatialCardDto(
    val id: String,
    val pin: PinterestPinDto,
    val frame: SpatialRectDto,
    val columnIndex: Int = 0,
    val ringIndex: Int = 0
)

@Serializable
data class PinterestBatchImportReportDto(
    val importedAssets: List<AssetDto> = emptyList(),
    @SerialName("skippedDuplicatePinIDs") val skippedDuplicatePinIds: List<String> = emptyList(),
    @SerialName("failedPinIDs") val failedPinIds: List<String> = emptyList(),
    val errors: List<String> = emptyList()
)

@Serializable
data class PinterestBoardsImportReportDto(
    @SerialName("createdOrReusedFolderIDs") val createdOrReusedFolderIds: List<String> = emptyList(),
    val importedAssetCount: Int = 0,
    val skippedDuplicateCount: Int = 0,
    val failedPinCount: Int = 0,
    val errors: List<String> = emptyList(),
    val wasCancelled: Boolean = false
)

@Serializable
data class FolderSuggestionDto(
    @SerialName("folderID") val folderId: String,
    val folderName: String,
    val confidence: Double = 0.0,
    val reason: String = ""
)

@Serializable
data class ScoredAssetDto(
    val asset: AssetDto,
    val score: Double = 0.0,
    val matchReasons: List<String> = emptyList()
)

@Serializable
data class FilterCriteriaDto(
    val searchQuery: String = "",
    val kinds: Set<String> = emptySet(),
    val selectedColorHex: String? = null,
    val colorTolerance: Double = 28.0,
    val shape: String? = null,
    val minRating: Int = 0,
    val tags: Set<String> = emptySet(),
    @SerialName("folderID") val folderId: String? = null,
    val includeSubfolders: Boolean = true,
    val onlyInbox: Boolean = false,
    val onlyUntagged: Boolean = false,
    val onlyRecentDays: Int? = null,
    val onlyPinnedOffline: Boolean = false,
    val includeTrashed: Boolean = false,
    val onlyTrashed: Boolean = false,
    val sortBy: String = "newest"
) {
    val hasVisualFilters: Boolean
        get() = kinds.isNotEmpty() ||
            selectedColorHex != null ||
            shape != null ||
            minRating > 0 ||
            tags.isNotEmpty() ||
            onlyPinnedOffline
}

@Serializable
data class CacheStatsDto(
    val thumbnailBytes: Long = 0L,
    val originalCacheBytes: Long = 0L,
    val pinnedOfflineBytes: Long = 0L,
    val budgetBytes: Long = 4L * 1024L * 1024L * 1024L,
    val cachedOriginalCount: Int = 0,
    val pinnedAssetCount: Int = 0
)

@Serializable
data class SyncBackendProfileDto(
    val id: String = "",
    val name: String = "Google Drive",
    val mode: String = "directAPIWithGDirect",
    val isEnabled: Boolean = true,
    val isPrimary: Boolean = false,
    val rootFolderName: String = "Charkle",
    @SerialName("sharedFolderURLOrID") val sharedFolderUrlOrId: String = "",
    val mountPath: String = "",
    @SerialName("selectedGDirectAccount") val selectedGDirectAccount: String? = null,
    @SerialName("useGDirectIPAcceleration") val useGDirectIpAcceleration: Boolean = true,
    @SerialName("iCloudFolderName") val icloudFolderName: String = "Charkle",
    @SerialName("iCloudCustomFolderPath") val icloudCustomFolderPath: String = "",
    @SerialName("iCloudContainerIdentifier") val icloudContainerIdentifier: String = "",
    @SerialName("webDAVServerURL") val webdavServerUrl: String = "",
    @SerialName("webDAVUsername") val webdavUsername: String = "",
    @SerialName("webDAVRemotePath") val webdavRemotePath: String = "/Charkle",
    val localLibraryPath: String = ""
)

@Serializable
data class DriveSyncConfigDto(
    val mode: String = "localOnly",
    val rootFolderName: String = "Charkle",
    @SerialName("sharedFolderURLOrID") val sharedFolderUrlOrId: String = "",
    val mountPath: String = "",
    @SerialName("selectedGDirectAccount") val selectedGDirectAccount: String? = null,
    @SerialName("useGDirectIPAcceleration") val useGDirectIpAcceleration: Boolean = true,
    @SerialName("iCloudFolderName") val icloudFolderName: String = "Charkle",
    @SerialName("iCloudCustomFolderPath") val icloudCustomFolderPath: String = "",
    @SerialName("webDAVServerURL") val webdavServerUrl: String = "",
    @SerialName("webDAVUsername") val webdavUsername: String = "",
    @SerialName("webDAVRemotePath") val webdavRemotePath: String = "/Charkle",
    val localLibraryPath: String = "",
    val backends: List<SyncBackendProfileDto> = emptyList(),
    val autoSyncIntervalSeconds: Int = 120,
    val syncThumbnails: Boolean = true,
    val syncEmbeddings: Boolean = true
)

@Serializable
data class DriveAccountInfoDto(
    val displayName: String = "",
    val email: String = "",
    val storageUsedBytes: Long? = null,
    val storageLimitBytes: Long? = null,
    val source: String = ""
)

internal fun isSyncPhaseActive(phase: JsonElement?): Boolean {
    return when (phase) {
        is JsonPrimitive -> {
            val raw = phase.content
            raw.equals("scanning", ignoreCase = true) || raw.equals("merging", ignoreCase = true)
        }
        is JsonObject -> phase.containsKey("uploading") || phase.containsKey("downloading")
        else -> false
    }
}

@Serializable
data class SyncBackendStatusDto(
    @SerialName("backendID") val backendId: String = "",
    val name: String = "",
    val mode: String = "localOnly",
    val isEnabled: Boolean = true,
    val isPrimary: Boolean = false,
    val phase: JsonElement? = null,
    val lastSyncedAt: Double? = null,
    val account: DriveAccountInfoDto? = null,
    val lastError: String? = null,
    val currentDetail: String? = null,
    val progressFraction: Double? = null,
    val locationSummary: String = ""
) {
    val isSyncing: Boolean
        get() = isSyncPhaseActive(phase)
}

@Serializable
data class SyncStatusDto(
    val phase: JsonElement? = null,
    val lastSyncedAt: Double? = null,
    val currentDetail: String? = null,
    val progressFraction: Double? = null,
    val pendingOpCount: Int = 0,
    val activeMode: String = "localOnly",
    val lastError: String? = null,
    val account: DriveAccountInfoDto? = null,
    val backendStatuses: List<SyncBackendStatusDto> = emptyList()
) {
    val isSyncing: Boolean
        get() = isSyncPhaseActive(phase) || backendStatuses.any { it.isSyncing }
}

@Serializable
data class QuickJumpMatchDto(
    val id: String,
    val kind: String,
    val title: String,
    val subtitle: String = "",
    @SerialName("targetUUID") val targetUuid: String? = null,
    val tagName: String? = null,
    val score: Double = 0.0
)

@Serializable
data class SemanticSearchHitDto(
    val asset: AssetDto,
    val score: Double = 0.0,
    val reason: String = "",
    val sourceLabel: String = ""
)

@Serializable
data class SemanticSearchReportDto(
    val query: String = "",
    val summary: String = "",
    val hits: List<SemanticSearchHitDto> = emptyList()
)

@Serializable
data class SyncReportDto(
    @SerialName("downloadedOps") val pulledOps: Int = 0,
    @SerialName("uploadedOps") val pushedOps: Int = 0,
    val discoveredRemoteAssets: Int = 0,
    val updatedBoards: Int = 0,
    val reconciledRenames: Int = 0,
    val downloadedThumbnails: Int = 0,
    val durationSeconds: Double = 0.0
)

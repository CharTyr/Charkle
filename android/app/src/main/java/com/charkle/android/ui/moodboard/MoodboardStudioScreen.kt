@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.moodboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.RotateRight
import androidx.compose.material.icons.automirrored.rounded.StickyNote2
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material.icons.rounded.AddPhotoAlternate
import androidx.compose.material.icons.rounded.AutoAwesomeMosaic
import androidx.compose.material.icons.rounded.Brush
import androidx.compose.material.icons.rounded.CenterFocusStrong
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DashboardCustomize
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Flip
import androidx.compose.material.icons.rounded.FlipToFront
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.LockOpen
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.MyLocation
import androidx.compose.material.icons.rounded.OpenInFull
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import coil3.compose.AsyncImage
import com.charkle.android.core.AssetDto
import com.charkle.android.core.AssetRefNodeDto
import com.charkle.android.core.AutoLayoutConfigDto
import com.charkle.android.core.BoardConnectorDto
import com.charkle.android.core.BoardLayoutModeDto
import com.charkle.android.core.BoardNodeDto
import com.charkle.android.core.BoardNodeKindDto
import com.charkle.android.core.BoardPointDto
import com.charkle.android.core.BoardRectDto
import com.charkle.android.core.EditorialLayoutResultDto
import com.charkle.android.core.FilterCriteriaDto
import com.charkle.android.core.GroupFrameNodeDto
import com.charkle.android.core.InkStrokeDto
import com.charkle.android.core.InkStrokePointDto
import com.charkle.android.core.LabColorDto
import com.charkle.android.core.MoodboardDocumentDto
import com.charkle.android.core.NoteNodeDto
import com.charkle.android.core.cocoaNowSeconds
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

private val StudioInkColors = listOf("#2A60E0", "#E05A47", "#249A4B", "#C98212", "#18191C", "#FFFFFF")

private data class NotePalette(
    val background: Color,
    val foreground: Color,
    val border: Color,
    val previewSwatch: Color
)

private fun resolveNotePalette(style: String, isDark: Boolean): NotePalette {
    return if (isDark) {
        when (style) {
            "ink" -> NotePalette(
                background = Color(0xFF23262E),
                foreground = Color(0xFFF2F3F5),
                border = Color.White.copy(alpha = 0.22f),
                previewSwatch = Color(0xFF23262E)
            )
            "warm" -> NotePalette(
                background = Color(0xFF3B3124),
                foreground = Color(0xFFF6E9D3),
                border = Color(0xFFD4B483).copy(alpha = 0.42f),
                previewSwatch = Color(0xFF6B563A)
            )
            "sage" -> NotePalette(
                background = Color(0xFF223428),
                foreground = Color(0xFFE1F1E5),
                border = Color(0xFF8DB596).copy(alpha = 0.42f),
                previewSwatch = Color(0xFF3E634B)
            )
            "slate" -> NotePalette(
                background = Color(0xFF222F3D),
                foreground = Color(0xFFE1ECF7),
                border = Color(0xFF8AA8C7).copy(alpha = 0.42f),
                previewSwatch = Color(0xFF3F5973)
            )
            else -> NotePalette(
                background = Color(0xFFE8E7E3),
                foreground = Color(0xFF1A1C20),
                border = Color.White.copy(alpha = 0.30f),
                previewSwatch = Color(0xFFE8E7E3)
            )
        }
    } else {
        when (style) {
            "ink" -> NotePalette(
                background = Color(0xFF1D1F24),
                foreground = Color(0xFFF1F2F4),
                border = Color.White.copy(alpha = 0.14f),
                previewSwatch = Color(0xFF1D1F24)
            )
            "warm" -> NotePalette(
                background = Color(0xFFF7F0E4),
                foreground = Color(0xFF392F22),
                border = Color(0xFF8C6F47).copy(alpha = 0.24f),
                previewSwatch = Color(0xFFF2E5CE)
            )
            "sage" -> NotePalette(
                background = Color(0xFFE8F0EA),
                foreground = Color(0xFF203227),
                border = Color(0xFF4D7359).copy(alpha = 0.24f),
                previewSwatch = Color(0xFFD5E6D9)
            )
            "slate" -> NotePalette(
                background = Color(0xFFE9EEF3),
                foreground = Color(0xFF1F2B36),
                border = Color(0xFF4E6780).copy(alpha = 0.24f),
                previewSwatch = Color(0xFFD6E2ED)
            )
            else -> NotePalette(
                background = Color(0xFFFFFFFF),
                foreground = Color(0xFF1D1F23),
                border = Color(0xFF18191C).copy(alpha = 0.12f),
                previewSwatch = Color(0xFFFFFFFF)
            )
        }
    }
}

private fun resolveGroupTintColor(tint: String): Color = when (tint) {
    "sand" -> Color(0xFFB5956B)
    "sage" -> Color(0xFF6B8E76)
    "slate" -> Color(0xFF627A94)
    "terracotta" -> Color(0xFFBA6B55)
    "ocean" -> Color(0xFF4D7E97)
    else -> Color(0xFF7D838B)
}

private fun rotateLocalDeltaToParent(delta: Offset, rotationDegrees: Double): Offset {
    if (rotationDegrees == 0.0) return delta
    val rad = Math.toRadians(rotationDegrees)
    val c = cos(rad).toFloat()
    val s = sin(rad).toFloat()
    return Offset(
        x = delta.x * c - delta.y * s,
        y = delta.x * s + delta.y * c
    )
}

private fun connectorEndpoint(
    node: BoardNodeDto,
    other: BoardNodeDto,
    anchor: String,
    scalePx: Float,
    offsetX: Float,
    offsetY: Float
): Pair<Offset, Offset> {
    val left = node.frame.x.toFloat() * scalePx + offsetX
    val top = node.frame.y.toFloat() * scalePx + offsetY
    val width = node.frame.width.toFloat() * scalePx
    val height = node.frame.height.toFloat() * scalePx
    val cx = left + width * 0.5f
    val cy = top + height * 0.5f

    val otherCx = (other.frame.x + other.frame.width * 0.5).toFloat() * scalePx + offsetX
    val otherCy = (other.frame.y + other.frame.height * 0.5).toFloat() * scalePx + offsetY
    val dx = otherCx - cx
    val dy = otherCy - cy

    val resolvedAnchor = if (anchor.equals("auto", ignoreCase = true)) {
        if (abs(dx) >= abs(dy)) {
            if (dx >= 0f) "trailing" else "leading"
        } else {
            if (dy >= 0f) "bottom" else "top"
        }
    } else {
        anchor.lowercase()
    }

    return when (resolvedAnchor) {
        "top" -> Offset(cx, top) to Offset(0f, -1f)
        "bottom" -> Offset(cx, top + height) to Offset(0f, 1f)
        "leading" -> Offset(left, cy) to Offset(-1f, 0f)
        "trailing" -> Offset(left + width, cy) to Offset(1f, 0f)
        else -> Offset(cx, cy) to Offset(if (dx >= 0f) 1f else -1f, 0f)
    }
}

@Composable
fun MoodboardStudioScreen(
    boardId: String,
    state: CharkleUiState,
    store: CharkleAppStore,
    onClose: () -> Unit,
    onOpenAsset: (AssetDto) -> Unit,
    onRevealAssetInLibrary: (String) -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val isDark = LocalCharkleExtendedColors.current.isDark
    val floatingSurface = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh
    } else {
        MaterialTheme.colorScheme.surfaceContainerLowest
    }

    var document by remember(boardId) { mutableStateOf<MoodboardDocumentDto?>(null) }
    var loadFailed by remember(boardId) { mutableStateOf(false) }
    var assetsById by remember(boardId) { mutableStateOf<Map<String, AssetDto>>(emptyMap()) }
    val thumbFileCache = remember(boardId) { mutableStateMapOf<String, File>() }
    var selectedNodeId by remember(boardId) { mutableStateOf<String?>(null) }
    var connectingFromNodeId by remember(boardId) { mutableStateOf<String?>(null) }

    var canvasOffsetX by remember(boardId) { mutableFloatStateOf(40f) }
    var canvasOffsetY by remember(boardId) { mutableFloatStateOf(40f) }
    var canvasZoom by remember(boardId) { mutableFloatStateOf(0.85f) }
    var hasInitializedViewport by remember(boardId) { mutableStateOf(false) }
    var latestEditorialLayout by remember(boardId) { mutableStateOf<EditorialLayoutResultDto?>(null) }
    var latestEditorialScrollPx by remember(boardId) { mutableFloatStateOf(0f) }
    var latestEditorialScale by remember(boardId) { mutableFloatStateOf(1f) }
    var stageWidthPxState by remember(boardId) { mutableFloatStateOf(0f) }
    var stageHeightPxState by remember(boardId) { mutableFloatStateOf(0f) }

    var isDrawingInk by remember(boardId) { mutableStateOf(false) }
    var activeInkHex by remember { mutableStateOf("#2A60E0") }
    var activeStrokePoints by remember(boardId) { mutableStateOf<List<InkStrokePointDto>>(emptyList()) }

    var showAssetPicker by remember { mutableStateOf(false) }
    var pickerAssets by remember { mutableStateOf<List<AssetDto>>(emptyList()) }
    var isLoadingPickerAssets by remember { mutableStateOf(false) }

    var showNoteDialog by remember { mutableStateOf(false) }
    var editingNoteNodeId by remember { mutableStateOf<String?>(null) }
    var noteTitleDraft by remember { mutableStateOf("") }
    var noteTextDraft by remember { mutableStateOf("") }
    var noteStyleDraft by remember { mutableStateOf("warm") }

    var showGroupDialog by remember { mutableStateOf(false) }
    var editingGroupNodeId by remember { mutableStateOf<String?>(null) }
    var groupTitleDraft by remember { mutableStateOf("") }
    var groupTintDraft by remember { mutableStateOf("sage") }

    var showTopMenu by remember { mutableStateOf(false) }
    var isExporting by remember { mutableStateOf(false) }
    var isClosing by remember(boardId) { mutableStateOf(false) }
    var saveDebounceJob by remember(boardId) { mutableStateOf<Job?>(null) }
    var pendingUnsavedDoc by remember(boardId) { mutableStateOf<MoodboardDocumentDto?>(null) }

    fun persistDocument(updated: MoodboardDocumentDto, immediate: Boolean = false) {
        document = updated
        pendingUnsavedDoc = updated
        saveDebounceJob?.cancel()
        saveDebounceJob = scope.launch {
            if (!immediate) delay(280)
            withContext(NonCancellable) {
                store.saveMoodboard(updated)
            }
            if (pendingUnsavedDoc === updated) {
                pendingUnsavedDoc = null
            }
        }
    }

    suspend fun saveLatestForExport(fallback: MoodboardDocumentDto): MoodboardDocumentDto? {
        saveDebounceJob?.cancel()
        saveDebounceJob = null
        val toSave = pendingUnsavedDoc ?: document ?: fallback
        pendingUnsavedDoc = null
        return withContext(NonCancellable) {
            store.saveMoodboard(toSave)
        }
    }

    fun closeWithFlush() {
        if (isClosing) return
        isClosing = true
        val pending = pendingUnsavedDoc
        saveDebounceJob?.cancel()
        saveDebounceJob = null
        if (pending != null) {
            pendingUnsavedDoc = null
            scope.launch {
                try {
                    withContext(NonCancellable) {
                        store.saveMoodboard(pending)
                    }
                    onClose()
                } finally {
                    isClosing = false
                }
            }
        } else {
            onClose()
            isClosing = false
        }
    }

    fun revealWithFlush(assetId: String) {
        val pending = pendingUnsavedDoc
        saveDebounceJob?.cancel()
        saveDebounceJob = null
        if (pending != null) {
            pendingUnsavedDoc = null
            scope.launch {
                withContext(NonCancellable) {
                    store.saveMoodboard(pending)
                }
                onRevealAssetInLibrary(assetId)
            }
        } else {
            onRevealAssetInLibrary(assetId)
        }
    }

    // Reliable fallback flush if the composable leaves composition unexpectedly
    DisposableEffect(boardId) {
        onDispose {
            saveDebounceJob?.cancel()
            saveDebounceJob = null
            val remaining = pendingUnsavedDoc
            if (remaining != null) {
                pendingUnsavedDoc = null
                CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
                    store.saveMoodboard(remaining)
                }
            }
        }
    }

    BackHandler {
        when {
            isDrawingInk -> {
                isDrawingInk = false
                activeStrokePoints = emptyList()
            }
            connectingFromNodeId != null -> {
                connectingFromNodeId = null
            }
            selectedNodeId != null -> {
                selectedNodeId = null
            }
            else -> closeWithFlush()
        }
    }

    LaunchedEffect(boardId) {
        loadFailed = false
        val loaded = store.loadMoodboard(boardId)
        if (loaded == null) {
            loadFailed = true
            return@LaunchedEffect
        }
        document = loaded
        val map = buildMap<String, AssetDto> {
            state.assets.forEach { put(it.id.uppercase(), it) }
            for (node in loaded.nodes) {
                val aid = node.referencedAssetId ?: continue
                val key = aid.uppercase()
                if (!containsKey(key)) {
                    store.repository.fetchAsset(aid)?.let { put(key, it) }
                }
            }
        }
        assetsById = map
    }

    // Load all non-trashed library assets when asset picker opens (independent of current gallery filter)
    LaunchedEffect(showAssetPicker) {
        if (!showAssetPicker) return@LaunchedEffect
        isLoadingPickerAssets = true
        val fetched = runCatching {
            store.repository.fetchAssets(FilterCriteriaDto())
        }.getOrElse {
            state.assets.filterNot { it.isTrashed }
        }
        pickerAssets = fetched
        isLoadingPickerAssets = false
    }

    fun recomputePalette(nodes: List<BoardNodeDto>, currentAssets: Map<String, AssetDto>): List<LabColorDto> {
        val seen = LinkedHashMap<String, LabColorDto>()
        for (node in nodes) {
            val asset = node.referencedAssetId?.let { currentAssets[it.uppercase()] } ?: continue
            for (swatch in asset.dominantColors.take(2)) {
                val key = swatch.hex.uppercase()
                if (!seen.containsKey(key)) seen[key] = swatch
                if (seen.size >= 8) break
            }
            if (seen.size >= 8) break
        }
        return seen.values.toList()
    }

    fun shareExportedFile(file: File, mimeType: String, chooserTitle: String) {
        runCatching {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, chooserTitle))
        }.onFailure { err ->
            store.showToast("无法打开系统分享：${err.message ?: "未找到可用应用"}")
        }
    }

    fun fitCanvasToContent(viewportWidthPx: Float, viewportHeightPx: Float) {
        val doc = document ?: return
        if (viewportWidthPx <= 0f || viewportHeightPx <= 0f) return
        if (doc.nodes.isEmpty() && doc.inkStrokes.isEmpty()) {
            canvasZoom = 1f
            canvasOffsetX = 40f
            canvasOffsetY = 40f
            return
        }
        val minX = buildList {
            doc.nodes.forEach { add(it.frame.x.toFloat()) }
            doc.inkStrokes.forEach { s -> s.points.forEach { add(it.x.toFloat()) } }
        }.minOrNull() ?: 0f
        val minY = buildList {
            doc.nodes.forEach { add(it.frame.y.toFloat()) }
            doc.inkStrokes.forEach { s -> s.points.forEach { add(it.y.toFloat()) } }
        }.minOrNull() ?: 0f
        val maxX = buildList {
            doc.nodes.forEach { add((it.frame.x + it.frame.width).toFloat()) }
            doc.inkStrokes.forEach { s -> s.points.forEach { add(it.x.toFloat()) } }
        }.maxOrNull() ?: 240f
        val maxY = buildList {
            doc.nodes.forEach { add((it.frame.y + it.frame.height).toFloat()) }
            doc.inkStrokes.forEach { s -> s.points.forEach { add(it.y.toFloat()) } }
        }.maxOrNull() ?: 240f

        val contentW = (maxX - minX).coerceAtLeast(180f)
        val contentH = (maxY - minY).coerceAtLeast(180f)
        val scaleX = (viewportWidthPx * 0.86f) / (contentW * density.density)
        val scaleY = (viewportHeightPx * 0.72f) / (contentH * density.density)
        val fitZoom = minOf(scaleX, scaleY).coerceIn(0.35f, 1.35f)
        canvasZoom = fitZoom
        canvasOffsetX = (viewportWidthPx - contentW * density.density * fitZoom) * 0.5f - minX * density.density * fitZoom
        canvasOffsetY = (viewportHeightPx * 0.84f - contentH * density.density * fitZoom) * 0.5f - minY * density.density * fitZoom
    }

    fun viewportCenterWorld(): Offset {
        val scalePx = (canvasZoom * density.density).coerceAtLeast(0.001f)
        val cx = if (stageWidthPxState > 0f) stageWidthPxState * 0.5f else 180f * density.density
        val cy = if (stageHeightPxState > 0f) stageHeightPxState * 0.42f else 240f * density.density
        return Offset(
            x = (cx - canvasOffsetX) / scalePx,
            y = (cy - canvasOffsetY) / scalePx
        )
    }

    fun switchToFreeformSmoothly(cur: MoodboardDocumentDto, stageWidthDp: Double) {
        if (!cur.mode.isAutoEditorial) return
        scope.launch {
            isDrawingInk = false
            activeStrokePoints = emptyList()
            connectingFromNodeId = null

            val solved = latestEditorialLayout ?: store.solveEditorialLayout(cur, stageWidthDp.coerceAtLeast(320.0))

            val updatedNodes = if (solved != null) {
                val now = cocoaNowSeconds()
                cur.nodes.map { node ->
                    val rect = solved.frames[node.id.uppercase()] ?: solved.frames[node.id]
                    if (rect != null) {
                        node.copy(frame = rect, updatedAt = now)
                    } else {
                        node
                    }
                }
            } else {
                cur.nodes
            }

            if (solved != null) {
                val targetScale = latestEditorialScale.coerceIn(0.5f, 1.0f)
                canvasZoom = targetScale
                canvasOffsetX = 0f
                canvasOffsetY = -latestEditorialScrollPx
                hasInitializedViewport = true
            }

            persistDocument(
                cur.copy(
                    mode = BoardLayoutModeDto.freeform(),
                    nodes = updatedNodes,
                    viewportZoom = canvasZoom.toDouble(),
                    viewportCenter = BoardPointDto(
                        x = viewportCenterWorld().x.toDouble(),
                        y = viewportCenterWorld().y.toDouble()
                    ),
                    updatedAt = cocoaNowSeconds()
                ),
                immediate = true
            )
        }
    }

    fun switchToAutoEditorial(cur: MoodboardDocumentDto, config: AutoLayoutConfigDto) {
        if (cur.mode.isAutoEditorial && cur.mode.editorialConfig?.style == config.style) return
        isDrawingInk = false
        activeStrokePoints = emptyList()
        connectingFromNodeId = null
        persistDocument(
            cur.copy(
                mode = BoardLayoutModeDto.autoEditorial(config),
                updatedAt = cocoaNowSeconds()
            ),
            immediate = true
        )
    }

    fun toggleConnectorBetween(fromId: String, toId: String) {
        val cur = document ?: return
        if (fromId.equals(toId, ignoreCase = true)) {
            connectingFromNodeId = null
            return
        }
        val existing = cur.connectors.firstOrNull { conn ->
            (conn.fromNodeId.equals(fromId, ignoreCase = true) && conn.toNodeId.equals(toId, ignoreCase = true)) ||
                (conn.fromNodeId.equals(toId, ignoreCase = true) && conn.toNodeId.equals(fromId, ignoreCase = true))
        }
        val nextConnectors = if (existing != null) {
            cur.connectors.filterNot { it.id == existing.id }
        } else {
            cur.connectors + BoardConnectorDto(
                id = UUID.randomUUID().toString().uppercase(),
                fromNodeId = fromId.uppercase(),
                fromAnchor = "auto",
                toNodeId = toId.uppercase(),
                toAnchor = "auto",
                colorHex = "#5C6672",
                style = "curved",
                dashed = false,
                updatedAt = cocoaNowSeconds()
            )
        }
        connectingFromNodeId = null
        selectedNodeId = toId
        persistDocument(
            cur.copy(connectors = nextConnectors, updatedAt = cocoaNowSeconds()),
            immediate = true
        )
        store.showToast(if (existing != null) "已断开两个元素之间的连线" else "已建立元素连线")
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        val doc = document
        if (doc == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                if (loadFailed) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.padding(24.dp)
                    ) {
                        Text("未能加载该情绪板", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "情绪板可能已被删除或尚未同步完成。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Button(onClick = { closeWithFlush() }, shape = CircleShape) {
                            Text("返回情绪板列表")
                        }
                    }
                } else {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        LoadingIndicator()
                        Spacer(Modifier.height(10.dp))
                        Text("正在打开情绪板…", style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        } else {
            val activeStyle = if (doc.mode.isAutoEditorial) {
                doc.mode.editorialConfig?.style ?: "balanced"
            } else {
                null
            }

            Column(modifier = Modifier.fillMaxSize()) {
                // Top Studio App Bar (Pure Zone A Neutral)
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    tonalElevation = 1.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = { closeWithFlush() }) {
                            Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回情绪板列表")
                        }
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = doc.title,
                                style = MaterialTheme.typography.titleMedium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            val modeLabel = if (doc.mode.isAutoEditorial) {
                                when (activeStyle) {
                                    "magazine" -> "自动排版 · 杂志主次"
                                    "compact" -> "自动排版 · 紧凑拼贴"
                                    else -> "自动排版 · 呼吸均衡"
                                }
                            } else {
                                "自由画布 · ${(canvasZoom * 100).roundToInt()}%"
                            }
                            Text(
                                text = "$modeLabel · ${doc.nodes.size} 个元素",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }

                        if (isExporting) {
                            LoadingIndicator(modifier = Modifier.size(28.dp))
                        }

                        Box {
                            IconButton(onClick = { showTopMenu = true }) {
                                Icon(Icons.Rounded.MoreVert, contentDescription = "画布与导出菜单")
                            }
                            DropdownMenu(expanded = showTopMenu, onDismissRequest = { showTopMenu = false }) {
                                DropdownMenuItem(
                                    text = { Text(if (!doc.mode.isAutoEditorial) "自由画布  ✓" else "切换为自由画布") },
                                    leadingIcon = { Icon(Icons.Rounded.OpenInFull, null) },
                                    onClick = {
                                        showTopMenu = false
                                        val latest = document ?: doc
                                        val widthDp = if (stageWidthPxState > 0f) {
                                            (stageWidthPxState / density.density).toDouble()
                                        } else {
                                            390.0
                                        }
                                        switchToFreeformSmoothly(latest, widthDp)
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text(if (activeStyle == "balanced") "自动排版 · 呼吸均衡  ✓" else "自动排版 · 呼吸均衡") },
                                    leadingIcon = { Icon(Icons.Rounded.AutoAwesomeMosaic, null) },
                                    onClick = {
                                        showTopMenu = false
                                        val latest = document ?: doc
                                        val cfg = AutoLayoutConfigDto(columns = 2, spacing = 14.0, style = "balanced")
                                        switchToAutoEditorial(latest, cfg)
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text(if (activeStyle == "magazine") "自动排版 · 杂志主次  ✓" else "自动排版 · 杂志主次") },
                                    leadingIcon = { Icon(Icons.Rounded.DashboardCustomize, null) },
                                    onClick = {
                                        showTopMenu = false
                                        val latest = document ?: doc
                                        val cfg = AutoLayoutConfigDto(columns = 2, spacing = 14.0, style = "magazine")
                                        switchToAutoEditorial(latest, cfg)
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text(if (activeStyle == "compact") "自动排版 · 紧凑拼贴  ✓" else "自动排版 · 紧凑拼贴") },
                                    leadingIcon = { Icon(Icons.Rounded.AutoAwesomeMosaic, null) },
                                    onClick = {
                                        showTopMenu = false
                                        val latest = document ?: doc
                                        val cfg = AutoLayoutConfigDto(columns = 3, spacing = 8.0, style = "compact")
                                        switchToAutoEditorial(latest, cfg)
                                    }
                                )
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text(if (isExporting) "正在导出…" else "导出高清 PNG 图片") },
                                    leadingIcon = { Icon(Icons.Rounded.Image, null) },
                                    enabled = !isExporting,
                                    onClick = {
                                        showTopMenu = false
                                        if (isExporting) return@DropdownMenuItem
                                        val latest = document ?: doc
                                        if (latest.nodes.isEmpty() && latest.inkStrokes.isEmpty()) {
                                            store.showToast("情绪板暂无元素，请先添加素材或便签后再导出")
                                            return@DropdownMenuItem
                                        }
                                        scope.launch {
                                            isExporting = true
                                            try {
                                                val saved = saveLatestForExport(latest)
                                                if (saved == null) {
                                                    store.showToast("保存情绪板失败，无法导出 PNG")
                                                    return@launch
                                                }
                                                val file = store.exportBoardPngFile(saved.id, saved.title)
                                                if (file != null && file.exists() && file.length() > 0L) {
                                                    shareExportedFile(file, "image/png", "分享情绪板高清图片")
                                                } else {
                                                    store.showToast("导出高清 PNG 失败，请确认情绪板素材已就绪")
                                                }
                                            } catch (err: Exception) {
                                                store.showToast("导出高清 PNG 失败：${err.message ?: "未知错误"}")
                                            } finally {
                                                isExporting = false
                                            }
                                        }
                                    }
                                )
                                DropdownMenuItem(
                                    text = { Text(if (isExporting) "正在导出…" else "导出 Figma / FigJam (.charkleboard)") },
                                    leadingIcon = { Icon(Icons.Rounded.Share, null) },
                                    enabled = !isExporting,
                                    onClick = {
                                        showTopMenu = false
                                        if (isExporting) return@DropdownMenuItem
                                        val latest = document ?: doc
                                        if (latest.nodes.isEmpty() && latest.inkStrokes.isEmpty()) {
                                            store.showToast("情绪板暂无元素，请先添加内容后再导出")
                                            return@DropdownMenuItem
                                        }
                                        scope.launch {
                                            isExporting = true
                                            try {
                                                val saved = saveLatestForExport(latest)
                                                if (saved == null) {
                                                    store.showToast("保存情绪板失败，无法打包 .charkleboard")
                                                    return@launch
                                                }
                                                val res = store.exportBoardFigmaBridgeFile(saved.id, saved.title)
                                                if (res != null) {
                                                    val (file, report) = res
                                                    store.showToast("已打包 ${report.objectCount} 个对象（${report.imageCount} 张图）")
                                                    shareExportedFile(file, "application/zip", "导出 .charkleboard 到 Figma")
                                                } else {
                                                    store.showToast("导出 .charkleboard 失败，请稍后重试")
                                                }
                                            } catch (err: Exception) {
                                                store.showToast("导出 .charkleboard 失败：${err.message ?: "未知错误"}")
                                            } finally {
                                                isExporting = false
                                            }
                                        }
                                    }
                                )
                            }
                        }
                    }
                }

                // Top Extracted Palette Ribbon
                if (doc.extractedPalette.isNotEmpty()) {
                    val cookieShape = MaterialShapes.Cookie6Sided.toShape()
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.background)
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = "主色板",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        doc.extractedPalette.take(8).forEach { swatch ->
                            Surface(
                                shape = CircleShape,
                                color = floatingSurface,
                                modifier = Modifier
                                    .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                                    .clip(CircleShape)
                                    .clickable {
                                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                        cm.setPrimaryClip(ClipData.newPlainText("Charkle Color", swatch.hex))
                                        store.showToast("已复制色值 ${swatch.hex}")
                                    }
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(5.dp)
                                ) {
                                    parseHexColor(swatch.hex)?.let { c ->
                                        Box(
                                            Modifier
                                                .size(14.dp)
                                                .clip(cookieShape)
                                                .background(c)
                                                .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, cookieShape)
                                        )
                                    }
                                    Text(
                                        text = swatch.hex,
                                        style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace)
                                    )
                                }
                            }
                        }
                    }
                }

                // Main Studio Stage (Auto Editorial OR Freeform Interactive Canvas)
                BoxWithConstraints(modifier = Modifier.weight(1f).fillMaxWidth()) {
                    val stageWidthPx = with(density) { maxWidth.toPx() }
                    val stageHeightPx = with(density) { maxHeight.toPx() }
                    val stageWidthDp = maxWidth.value.toDouble()

                    LaunchedEffect(stageWidthPx, stageHeightPx, doc.id, doc.mode.isAutoEditorial) {
                        stageWidthPxState = stageWidthPx
                        stageHeightPxState = stageHeightPx
                        if (!hasInitializedViewport && !doc.mode.isAutoEditorial && stageWidthPx > 0f && stageHeightPx > 0f) {
                            hasInitializedViewport = true
                            if (doc.nodes.isNotEmpty() || doc.inkStrokes.isNotEmpty()) {
                                fitCanvasToContent(stageWidthPx, stageHeightPx)
                            }
                        }
                    }

                    if (doc.mode.isAutoEditorial) {
                        AutoEditorialStage(
                            doc = doc,
                            containerWidthDp = stageWidthDp,
                            assetsById = assetsById,
                            thumbFileCache = thumbFileCache,
                            store = store,
                            selectedNodeId = selectedNodeId,
                            onLayoutSolved = { solved, scale, scrollPx ->
                                latestEditorialLayout = solved
                                latestEditorialScale = scale
                                latestEditorialScrollPx = scrollPx
                            },
                            onClearSelection = { selectedNodeId = null },
                            onSelectNode = { nodeId ->
                                selectedNodeId = if (selectedNodeId == nodeId) null else nodeId
                            },
                            onDoubleTapNode = { node ->
                                node.referencedAssetId?.let { aid -> assetsById[aid.uppercase()]?.let(onOpenAsset) }
                                if (node.kind.note != null) {
                                    if (node.isLocked) {
                                        store.showToast("便签已锁定，请先解锁后编辑")
                                    } else {
                                        editingNoteNodeId = node.id
                                        noteTitleDraft = node.kind.note.title.orEmpty()
                                        noteTextDraft = node.kind.note.text
                                        noteStyleDraft = node.kind.note.style
                                        showNoteDialog = true
                                    }
                                } else if (node.kind.groupFrame != null) {
                                    if (node.isLocked) {
                                        store.showToast("分组框已锁定，请先解锁后编辑")
                                    } else {
                                        editingGroupNodeId = node.id
                                        groupTitleDraft = node.kind.groupFrame.title
                                        groupTintDraft = node.kind.groupFrame.tint
                                        showGroupDialog = true
                                    }
                                }
                            }
                        )
                    } else {
                        FreeformCanvasStage(
                            doc = doc,
                            assetsById = assetsById,
                            thumbFileCache = thumbFileCache,
                            store = store,
                            selectedNodeId = selectedNodeId,
                            connectingFromNodeId = connectingFromNodeId,
                            canvasOffsetX = canvasOffsetX,
                            canvasOffsetY = canvasOffsetY,
                            canvasZoom = canvasZoom,
                            isDrawingInk = isDrawingInk,
                            activeInkHex = activeInkHex,
                            activeStrokePoints = activeStrokePoints,
                            onTransformCanvas = { centroid, pan, zoomChange ->
                                val prevZoom = canvasZoom
                                val nextZoom = (prevZoom * zoomChange).coerceIn(0.25f, 4.0f)
                                val ratio = if (prevZoom > 0.0001f) nextZoom / prevZoom else 1f
                                canvasOffsetX = centroid.x - (centroid.x - canvasOffsetX) * ratio + pan.x
                                canvasOffsetY = centroid.y - (centroid.y - canvasOffsetY) * ratio + pan.y
                                canvasZoom = nextZoom
                            },
                            onClearSelection = {
                                selectedNodeId = null
                                connectingFromNodeId = null
                            },
                            onSelectNode = { nodeId ->
                                val pendingSource = connectingFromNodeId
                                if (pendingSource != null) {
                                    toggleConnectorBetween(pendingSource, nodeId)
                                } else {
                                    selectedNodeId = if (selectedNodeId == nodeId) null else nodeId
                                }
                            },
                            onStartDragNode = { nodeId ->
                                if (selectedNodeId != nodeId) {
                                    selectedNodeId = nodeId
                                }
                            },
                            onDoubleTapNode = { node ->
                                connectingFromNodeId?.let { pendingSource ->
                                    toggleConnectorBetween(pendingSource, node.id)
                                    return@FreeformCanvasStage
                                }
                                node.referencedAssetId?.let { aid -> assetsById[aid.uppercase()]?.let(onOpenAsset) }
                                if (node.kind.note != null) {
                                    if (node.isLocked) {
                                        store.showToast("便签已锁定，请先解锁后编辑")
                                    } else {
                                        editingNoteNodeId = node.id
                                        noteTitleDraft = node.kind.note.title.orEmpty()
                                        noteTextDraft = node.kind.note.text
                                        noteStyleDraft = node.kind.note.style
                                        showNoteDialog = true
                                    }
                                } else if (node.kind.groupFrame != null) {
                                    if (node.isLocked) {
                                        store.showToast("分组框已锁定，请先解锁后编辑")
                                    } else {
                                        editingGroupNodeId = node.id
                                        groupTitleDraft = node.kind.groupFrame.title
                                        groupTintDraft = node.kind.groupFrame.tint
                                        showGroupDialog = true
                                    }
                                }
                            },
                            onMoveNode = { nodeId, dxWorld, dyWorld ->
                                val cur = document ?: return@FreeformCanvasStage
                                val now = cocoaNowSeconds()
                                val updatedNodes = cur.nodes.map { n ->
                                    if (n.id == nodeId && !n.isLocked) {
                                        n.copy(
                                            frame = n.frame.copy(x = n.frame.x + dxWorld, y = n.frame.y + dyWorld),
                                            updatedAt = now
                                        )
                                    } else n
                                }
                                persistDocument(cur.copy(nodes = updatedNodes, updatedAt = now))
                            },
                            onResizeNode = { nodeId, dwWorld, dhWorld ->
                                val cur = document ?: return@FreeformCanvasStage
                                val now = cocoaNowSeconds()
                                val updatedNodes = cur.nodes.map { n ->
                                    if (n.id == nodeId && !n.isLocked) {
                                        n.copy(
                                            frame = n.frame.copy(
                                                width = (n.frame.width + dwWorld).coerceAtLeast(100.0),
                                                height = (n.frame.height + dhWorld).coerceAtLeast(80.0)
                                            ),
                                            updatedAt = now
                                        )
                                    } else n
                                }
                                persistDocument(cur.copy(nodes = updatedNodes, updatedAt = now))
                            },
                            onInkDragStart = { worldPt ->
                                activeStrokePoints = listOf(InkStrokePointDto(worldPt.x.toDouble(), worldPt.y.toDouble(), 0.5))
                            },
                            onInkDragPoint = { worldPt ->
                                activeStrokePoints = activeStrokePoints + InkStrokePointDto(worldPt.x.toDouble(), worldPt.y.toDouble(), 0.5)
                            },
                            onInkDragCancel = {
                                activeStrokePoints = emptyList()
                            },
                            onInkDragEnd = {
                                val pts = activeStrokePoints
                                activeStrokePoints = emptyList()
                                if (pts.size >= 2) {
                                    val cur = document ?: return@FreeformCanvasStage
                                    val now = cocoaNowSeconds()
                                    val stroke = InkStrokeDto(
                                        id = UUID.randomUUID().toString().uppercase(),
                                        points = pts,
                                        colorHex = activeInkHex,
                                        lineWidth = 3.5,
                                        opacity = 0.92,
                                        zIndex = 1000 + cur.inkStrokes.size,
                                        createdAt = now
                                    )
                                    persistDocument(
                                        cur.copy(inkStrokes = cur.inkStrokes + stroke, updatedAt = now),
                                        immediate = true
                                    )
                                }
                            }
                        )
                    }

                    // Empty Board Hint
                    if (doc.nodes.isEmpty() && doc.inkStrokes.isEmpty() && !isDrawingInk) {
                        Surface(
                            shape = RoundedCornerShape(20.dp),
                            color = floatingSurface.copy(alpha = 0.92f),
                            modifier = Modifier
                                .align(Alignment.Center)
                                .padding(horizontal = 32.dp)
                                .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(20.dp))
                        ) {
                            Column(
                                modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                Text("空白情绪板", style = MaterialTheme.typography.titleSmall)
                                Text(
                                    "点击下方「素材」「便签」或「分组」开始拼贴灵感，双指捏合可缩放画布。",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }

                    // Connector Pairing Mode Banner
                    androidx.compose.animation.AnimatedVisibility(
                        visible = connectingFromNodeId != null,
                        enter = fadeIn() + slideInVertically { -it / 2 },
                        exit = fadeOut() + slideOutVertically { -it / 2 },
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .padding(top = 10.dp, start = 16.dp, end = 16.dp)
                    ) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primaryContainer,
                            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            shadowElevation = 6.dp
                        ) {
                            Row(
                                modifier = Modifier.padding(start = 14.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Icon(Icons.Rounded.Link, contentDescription = null, modifier = Modifier.size(16.dp))
                                Text("点击另一个元素以创建或断开连线", style = MaterialTheme.typography.labelMedium)
                                TextButton(onClick = { connectingFromNodeId = null }) {
                                    Text("取消")
                                }
                            }
                        }
                    }

                    // Bottom Floating Contextual Toolbars & Studio Dock
                    Column(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .navigationBarsPadding()
                            .padding(horizontal = 12.dp, vertical = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        val selectedNode = selectedNodeId?.let { id -> doc.nodes.firstOrNull { it.id == id } }
                        val selectedNodeConnectors = remember(selectedNode?.id, doc.connectors) {
                            val id = selectedNode?.id ?: return@remember emptyList()
                            doc.connectors.filter {
                                it.fromNodeId.equals(id, ignoreCase = true) || it.toNodeId.equals(id, ignoreCase = true)
                            }
                        }

                        AnimatedVisibility(
                            visible = selectedNode != null && !isDrawingInk && connectingFromNodeId == null,
                            enter = fadeIn() + slideInVertically { it / 2 },
                            exit = fadeOut() + slideOutVertically { it / 2 }
                        ) {
                            selectedNode?.let { node ->
                                SelectedNodeFloatingPill(
                                    node = node,
                                    isFreeform = !doc.mode.isAutoEditorial,
                                    hasConnectors = selectedNodeConnectors.isNotEmpty(),
                                    onOpenAsset = {
                                        node.referencedAssetId?.let { aid -> assetsById[aid.uppercase()]?.let(onOpenAsset) }
                                    },
                                    onRevealInLibrary = {
                                        node.referencedAssetId?.let { aid -> revealWithFlush(aid) }
                                    },
                                    onEditNote = {
                                        if (node.isLocked) {
                                            store.showToast("便签已锁定，请先解锁")
                                            return@SelectedNodeFloatingPill
                                        }
                                        editingNoteNodeId = node.id
                                        noteTitleDraft = node.kind.note?.title.orEmpty()
                                        noteTextDraft = node.kind.note?.text.orEmpty()
                                        noteStyleDraft = node.kind.note?.style ?: "warm"
                                        showNoteDialog = true
                                    },
                                    onEditGroup = {
                                        if (node.isLocked) {
                                            store.showToast("分组框已锁定，请先解锁")
                                            return@SelectedNodeFloatingPill
                                        }
                                        editingGroupNodeId = node.id
                                        groupTitleDraft = node.kind.groupFrame?.title.orEmpty()
                                        groupTintDraft = node.kind.groupFrame?.tint ?: "neutral"
                                        showGroupDialog = true
                                    },
                                    onStartConnect = {
                                        connectingFromNodeId = node.id
                                    },
                                    onClearConnectors = {
                                        val cur = document ?: return@SelectedNodeFloatingPill
                                        val now = cocoaNowSeconds()
                                        persistDocument(
                                            cur.copy(
                                                connectors = cur.connectors.filterNot {
                                                    it.fromNodeId.equals(node.id, ignoreCase = true) ||
                                                        it.toNodeId.equals(node.id, ignoreCase = true)
                                                },
                                                updatedAt = now
                                            ),
                                            immediate = true
                                        )
                                        store.showToast("已断开该元素的全部连线")
                                    },
                                    onRotate = {
                                        if (node.isLocked) {
                                            store.showToast("元素已锁定，请先解锁")
                                            return@SelectedNodeFloatingPill
                                        }
                                        val cur = document ?: return@SelectedNodeFloatingPill
                                        val now = cocoaNowSeconds()
                                        val nextRot = (node.rotationDegrees + 15.0) % 360.0
                                        persistDocument(
                                            cur.copy(
                                                nodes = cur.nodes.map {
                                                    if (it.id == node.id) it.copy(rotationDegrees = nextRot, updatedAt = now) else it
                                                },
                                                updatedAt = now
                                            ),
                                            immediate = true
                                        )
                                    },
                                    onFlipH = {
                                        if (node.isLocked) {
                                            store.showToast("元素已锁定，请先解锁")
                                            return@SelectedNodeFloatingPill
                                        }
                                        val cur = document ?: return@SelectedNodeFloatingPill
                                        val now = cocoaNowSeconds()
                                        persistDocument(
                                            cur.copy(
                                                nodes = cur.nodes.map {
                                                    if (it.id == node.id) it.copy(flipHorizontal = !it.flipHorizontal, updatedAt = now) else it
                                                },
                                                updatedAt = now
                                            ),
                                            immediate = true
                                        )
                                    },
                                    onToggleLock = {
                                        val cur = document ?: return@SelectedNodeFloatingPill
                                        val now = cocoaNowSeconds()
                                        val nextLocked = !node.isLocked
                                        persistDocument(
                                            cur.copy(
                                                nodes = cur.nodes.map {
                                                    if (it.id == node.id) it.copy(isLocked = nextLocked, updatedAt = now) else it
                                                },
                                                updatedAt = now
                                            ),
                                            immediate = true
                                        )
                                    },
                                    onBringToFront = {
                                        val cur = document ?: return@SelectedNodeFloatingPill
                                        val now = cocoaNowSeconds()
                                        val isGroup = node.kind.groupFrame != null
                                        val peers = cur.nodes.filter { (it.kind.groupFrame != null) == isGroup }
                                        val topZ = (peers.maxOfOrNull { it.zIndex } ?: 0) + 1
                                        persistDocument(
                                            cur.copy(
                                                nodes = cur.nodes.map {
                                                    if (it.id == node.id) it.copy(zIndex = topZ, updatedAt = now) else it
                                                },
                                                updatedAt = now
                                            ),
                                            immediate = true
                                        )
                                    },
                                    onDelete = {
                                        if (node.isLocked) {
                                            store.showToast("元素已锁定，请先解锁后移除")
                                            return@SelectedNodeFloatingPill
                                        }
                                        val cur = document ?: return@SelectedNodeFloatingPill
                                        val now = cocoaNowSeconds()
                                        val nextNodes = cur.nodes.filterNot { it.id == node.id }
                                        selectedNodeId = null
                                        persistDocument(
                                            cur.copy(
                                                nodes = nextNodes,
                                                connectors = cur.connectors.filterNot {
                                                    it.fromNodeId.equals(node.id, ignoreCase = true) ||
                                                        it.toNodeId.equals(node.id, ignoreCase = true)
                                                },
                                                extractedPalette = recomputePalette(nextNodes, assetsById),
                                                updatedAt = now
                                            ),
                                            immediate = true
                                        )
                                    }
                                )
                            }
                        }

                        AnimatedVisibility(
                            visible = isDrawingInk && !doc.mode.isAutoEditorial,
                            enter = fadeIn() + slideInVertically { it / 2 },
                            exit = fadeOut() + slideOutVertically { it / 2 }
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = floatingSurface,
                                shadowElevation = 8.dp,
                                modifier = Modifier.border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                            ) {
                                Row(
                                    modifier = Modifier
                                        .horizontalScroll(rememberScrollState())
                                        .padding(horizontal = 12.dp, vertical = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    StudioInkColors.forEach { hex ->
                                        val color = parseHexColor(hex) ?: Color.Black
                                        val active = activeInkHex.equals(hex, ignoreCase = true)
                                        Box(
                                            modifier = Modifier
                                                .size(if (active) 28.dp else 22.dp)
                                                .clip(CircleShape)
                                                .background(color)
                                                .border(
                                                    width = if (active) 2.5.dp else 1.dp,
                                                    color = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline.copy(alpha = 0.55f),
                                                    shape = CircleShape
                                                )
                                                .clickable { activeInkHex = hex }
                                        )
                                    }
                                    IconButton(
                                        onClick = {
                                            val cur = document ?: return@IconButton
                                            if (cur.inkStrokes.isNotEmpty()) {
                                                persistDocument(
                                                    cur.copy(
                                                        inkStrokes = cur.inkStrokes.dropLast(1),
                                                        updatedAt = cocoaNowSeconds()
                                                    ),
                                                    immediate = true
                                                )
                                            }
                                        },
                                        enabled = doc.inkStrokes.isNotEmpty(),
                                        modifier = Modifier.size(32.dp)
                                    ) {
                                        Icon(Icons.AutoMirrored.Rounded.Undo, contentDescription = "撤销笔迹", modifier = Modifier.size(18.dp))
                                    }
                                    TextButton(
                                        onClick = {
                                            isDrawingInk = false
                                            activeStrokePoints = emptyList()
                                        }
                                    ) {
                                        Text("完成")
                                    }
                                }
                            }
                        }

                        // Primary Bottom Studio Dock
                        Surface(
                            shape = CircleShape,
                            color = floatingSurface,
                            shadowElevation = 10.dp,
                            modifier = Modifier.border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                        ) {
                            Row(
                                modifier = Modifier
                                    .horizontalScroll(rememberScrollState())
                                    .padding(horizontal = 6.dp, vertical = 5.dp),
                                horizontalArrangement = Arrangement.spacedBy(2.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                StudioDockButton(
                                    icon = Icons.Rounded.AddPhotoAlternate,
                                    label = "素材",
                                    active = false,
                                    onClick = {
                                        isDrawingInk = false
                                        connectingFromNodeId = null
                                        showAssetPicker = true
                                    }
                                )
                                StudioDockButton(
                                    icon = Icons.AutoMirrored.Rounded.StickyNote2,
                                    label = "便签",
                                    active = false,
                                    onClick = {
                                        isDrawingInk = false
                                        connectingFromNodeId = null
                                        editingNoteNodeId = null
                                        noteTitleDraft = ""
                                        noteTextDraft = ""
                                        noteStyleDraft = "warm"
                                        showNoteDialog = true
                                    }
                                )
                                StudioDockButton(
                                    icon = Icons.Rounded.DashboardCustomize,
                                    label = "分组",
                                    active = false,
                                    onClick = {
                                        isDrawingInk = false
                                        connectingFromNodeId = null
                                        editingGroupNodeId = null
                                        groupTitleDraft = ""
                                        groupTintDraft = "sage"
                                        showGroupDialog = true
                                    }
                                )
                                if (!doc.mode.isAutoEditorial) {
                                    StudioDockButton(
                                        icon = Icons.Rounded.Brush,
                                        label = "手绘",
                                        active = isDrawingInk,
                                        onClick = {
                                            selectedNodeId = null
                                            connectingFromNodeId = null
                                            isDrawingInk = !isDrawingInk
                                            if (!isDrawingInk) activeStrokePoints = emptyList()
                                        }
                                    )
                                    StudioDockButton(
                                        icon = Icons.Rounded.CenterFocusStrong,
                                        label = "居中",
                                        active = false,
                                        onClick = { fitCanvasToContent(stageWidthPx, stageHeightPx) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Add Assets Multi-Select Sheet
    if (showAssetPicker) {
        val existingBoardAssetIds = remember(document?.nodes) {
            document?.nodes?.mapNotNull { it.referencedAssetId?.uppercase() }?.toSet().orEmpty()
        }
        ModalBottomSheet(
            onDismissRequest = { showAssetPicker = false },
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
        ) {
            MoodboardAssetPickerSheet(
                assets = pickerAssets,
                isLoading = isLoadingPickerAssets,
                existingBoardAssetIds = existingBoardAssetIds,
                thumbFileCache = thumbFileCache,
                store = store,
                onConfirm = { pickedAssets ->
                    showAssetPicker = false
                    val cur = document ?: return@MoodboardAssetPickerSheet
                    val updatedAssetMap = assetsById.toMutableMap().apply {
                        pickedAssets.forEach { put(it.id.uppercase(), it) }
                    }
                    assetsById = updatedAssetMap

                    val baseZ = (cur.nodes.filter { it.kind.groupFrame == null }.maxOfOrNull { it.zIndex } ?: 0) + 1
                    val existingCount = cur.nodes.size
                    val centerWorld = viewportCenterWorld()
                    val cols = pickedAssets.size.coerceAtMost(3).coerceAtLeast(1)
                    val startX = if (cur.mode.isAutoEditorial) {
                        36.0
                    } else {
                        centerWorld.x.toDouble() - (cols * 236.0 - 16.0) * 0.5
                    }
                    val startY = if (cur.mode.isAutoEditorial) {
                        36.0
                    } else {
                        centerWorld.y.toDouble() - 120.0
                    }
                    val now = cocoaNowSeconds()

                    val newNodes = pickedAssets.mapIndexed { index, asset ->
                        val col = index % cols
                        val row = index / cols
                        val width = 220.0
                        val height = (width / asset.aspectRatio.toDouble()).coerceIn(140.0, 340.0)
                        BoardNodeDto(
                            id = UUID.randomUUID().toString().uppercase(),
                            kind = BoardNodeKindDto(assetRef = AssetRefNodeDto(assetId = asset.id)),
                            frame = BoardRectDto(
                                x = startX + col * 236.0,
                                y = startY + row * 268.0,
                                width = width,
                                height = height
                            ),
                            zIndex = baseZ + index,
                            editorialOrder = existingCount + index,
                            updatedAt = now
                        )
                    }
                    val mergedNodes = cur.nodes + newNodes
                    persistDocument(
                        cur.copy(
                            nodes = mergedNodes,
                            extractedPalette = recomputePalette(mergedNodes, updatedAssetMap),
                            updatedAt = now
                        ),
                        immediate = true
                    )
                    store.showToast("已添加 ${newNodes.size} 张素材到情绪板")
                }
            )
        }
    }

    // Create / Edit Sticky Note Dialog
    if (showNoteDialog) {
        val styles = listOf("paper" to "纸白", "ink" to "墨黑", "warm" to "暖米", "sage" to "鼠尾草", "slate" to "石板蓝")
        AlertDialog(
            onDismissRequest = { showNoteDialog = false },
            title = { Text(if (editingNoteNodeId == null) "新增便签" else "编辑便签") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = noteTitleDraft,
                        onValueChange = { noteTitleDraft = it },
                        label = { Text("标题（可选）") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = noteTextDraft,
                        onValueChange = { noteTextDraft = it },
                        label = { Text("灵感批注或文字") },
                        minLines = 3,
                        maxLines = 6,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        styles.forEach { (id, label) ->
                            val swatch = resolveNotePalette(id, isDark).previewSwatch
                            FilterChip(
                                selected = noteStyleDraft == id,
                                onClick = { noteStyleDraft = id },
                                leadingIcon = {
                                    Box(
                                        modifier = Modifier
                                            .size(12.dp)
                                            .clip(CircleShape)
                                            .background(swatch)
                                            .border(0.75.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.55f), CircleShape)
                                    )
                                },
                                label = { Text(label) }
                            )
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val cur = document ?: return@Button
                        val cleanTitle = noteTitleDraft.trim().takeIf { it.isNotEmpty() }
                        val cleanText = noteTextDraft.trim()
                        if (cleanTitle == null && cleanText.isEmpty()) return@Button
                        val now = cocoaNowSeconds()

                        val editId = editingNoteNodeId
                        val nextNodes = if (editId != null) {
                            cur.nodes.map { n ->
                                if (n.id == editId) {
                                    val prevFontSize = n.kind.note?.fontSize ?: 14.0
                                    n.copy(
                                        kind = BoardNodeKindDto(
                                            note = NoteNodeDto(
                                                title = cleanTitle,
                                                text = cleanText,
                                                style = noteStyleDraft,
                                                fontSize = prevFontSize
                                            )
                                        ),
                                        updatedAt = now
                                    )
                                } else n
                            }
                        } else {
                            val topZ = (cur.nodes.filter { it.kind.groupFrame == null }.maxOfOrNull { it.zIndex } ?: 0) + 1
                            val center = viewportCenterWorld()
                            val placeX = if (cur.mode.isAutoEditorial) 36.0 else (center.x.toDouble() - 114.0)
                            val placeY = if (cur.mode.isAutoEditorial) {
                                val maxBottom = cur.nodes.maxOfOrNull { it.frame.y + it.frame.height } ?: 36.0
                                if (cur.nodes.isEmpty()) 48.0 else maxBottom + 24.0
                            } else {
                                center.y.toDouble() - 80.0
                            }
                            cur.nodes + BoardNodeDto(
                                id = UUID.randomUUID().toString().uppercase(),
                                kind = BoardNodeKindDto(
                                    note = NoteNodeDto(
                                        title = cleanTitle,
                                        text = cleanText,
                                        style = noteStyleDraft
                                    )
                                ),
                                frame = BoardRectDto(x = placeX, y = placeY, width = 228.0, height = 160.0),
                                zIndex = topZ,
                                editorialOrder = cur.nodes.size,
                                updatedAt = now
                            )
                        }
                        persistDocument(cur.copy(nodes = nextNodes, updatedAt = now), immediate = true)
                        showNoteDialog = false
                    },
                    enabled = noteTitleDraft.isNotBlank() || noteTextDraft.isNotBlank()
                ) { Text("保存") }
            },
            dismissButton = {
                TextButton(onClick = { showNoteDialog = false }) { Text("取消") }
            }
        )
    }

    // Create / Edit Group Frame Dialog
    if (showGroupDialog) {
        val tints = listOf(
            "neutral" to "中性灰",
            "sand" to "砂岩",
            "sage" to "苔绿",
            "slate" to "石青",
            "terracotta" to "陶土",
            "ocean" to "海蓝"
        )
        AlertDialog(
            onDismissRequest = { showGroupDialog = false },
            title = { Text(if (editingGroupNodeId == null) "新增分组框" else "编辑分组框") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = groupTitleDraft,
                        onValueChange = { groupTitleDraft = it },
                        label = { Text("分组标题（如：色彩方向 / 构图参考）") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        tints.forEach { (id, label) ->
                            FilterChip(
                                selected = groupTintDraft == id,
                                onClick = { groupTintDraft = id },
                                leadingIcon = {
                                    Box(
                                        modifier = Modifier
                                            .size(12.dp)
                                            .clip(CircleShape)
                                            .background(resolveGroupTintColor(id))
                                    )
                                },
                                label = { Text(label) }
                            )
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        val cur = document ?: return@Button
                        val now = cocoaNowSeconds()
                        val cleanTitle = groupTitleDraft.trim().ifEmpty { "新建分组" }
                        val editId = editingGroupNodeId
                        val nextNodes = if (editId != null) {
                            cur.nodes.map { n ->
                                if (n.id == editId) {
                                    n.copy(
                                        kind = BoardNodeKindDto(
                                            groupFrame = GroupFrameNodeDto(
                                                title = cleanTitle,
                                                tint = groupTintDraft
                                            )
                                        ),
                                        updatedAt = now
                                    )
                                } else n
                            }
                        } else {
                            val minZ = (cur.nodes.minOfOrNull { it.zIndex } ?: 0) - 1
                            val center = viewportCenterWorld()
                            val placeX = if (cur.mode.isAutoEditorial) 24.0 else (center.x.toDouble() - 170.0)
                            val placeY = if (cur.mode.isAutoEditorial) 24.0 else (center.y.toDouble() - 140.0)
                            cur.nodes + BoardNodeDto(
                                id = UUID.randomUUID().toString().uppercase(),
                                kind = BoardNodeKindDto(
                                    groupFrame = GroupFrameNodeDto(
                                        title = cleanTitle,
                                        tint = groupTintDraft
                                    )
                                ),
                                frame = BoardRectDto(x = placeX, y = placeY, width = 340.0, height = 280.0),
                                zIndex = minZ,
                                editorialOrder = cur.nodes.size,
                                updatedAt = now
                            )
                        }
                        persistDocument(
                            cur.copy(nodes = nextNodes, updatedAt = now),
                            immediate = true
                        )
                        showGroupDialog = false
                    }
                ) { Text(if (editingGroupNodeId == null) "添加" else "保存") }
            },
            dismissButton = {
                TextButton(onClick = { showGroupDialog = false }) { Text("取消") }
            }
        )
    }
}

@Composable
private fun AutoEditorialStage(
    doc: MoodboardDocumentDto,
    containerWidthDp: Double,
    assetsById: Map<String, AssetDto>,
    thumbFileCache: MutableMap<String, File>,
    store: CharkleAppStore,
    selectedNodeId: String?,
    onLayoutSolved: (EditorialLayoutResultDto, Float, Float) -> Unit,
    onClearSelection: () -> Unit,
    onSelectNode: (String) -> Unit,
    onDoubleTapNode: (BoardNodeDto) -> Unit
) {
    var layout by remember(doc.id) { mutableStateOf<EditorialLayoutResultDto?>(null) }
    val scrollState = rememberScrollState()
    val latestOnLayoutSolved by rememberUpdatedState(onLayoutSolved)
    val latestOnClearSelection by rememberUpdatedState(onClearSelection)

    LaunchedEffect(doc.id, doc.nodes, doc.mode, containerWidthDp) {
        val solved = store.solveEditorialLayout(doc, containerWidthDp.coerceAtLeast(320.0))
        if (solved != null) {
            layout = solved
        }
    }

    val solved = layout
    val maxRightDp = remember(solved, containerWidthDp) {
        val frameMaxRight = solved?.frames?.values?.maxOfOrNull { it.x + it.width } ?: 0.0
        maxOf(solved?.contentSize?.width ?: containerWidthDp, frameMaxRight, containerWidthDp)
    }
    val fitScale = remember(maxRightDp, containerWidthDp) {
        if (maxRightDp > containerWidthDp && maxRightDp > 0.0) {
            (containerWidthDp / maxRightDp).toFloat().coerceIn(0.5f, 1.0f)
        } else {
            1.0f
        }
    }

    LaunchedEffect(solved, fitScale, scrollState.value) {
        if (solved != null) {
            latestOnLayoutSolved(solved, fitScale, scrollState.value.toFloat())
        }
    }

    val contentHeightDp = (((solved?.contentSize?.height ?: 640.0) * fitScale) + 140.0).coerceAtLeast(640.0)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(contentHeightDp.dp)
                .pointerInput(Unit) {
                    detectTapGestures(onTap = { latestOnClearSelection() })
                }
        ) {
            val orderedNodes = remember(doc.nodes) { doc.nodes.sortedBy { it.zIndex } }
            orderedNodes.forEach { node ->
                key(node.id) {
                    val rawRect = solved?.frames?.get(node.id.uppercase()) ?: solved?.frames?.get(node.id) ?: node.frame
                    Box(
                        modifier = Modifier
                            .offset(x = (rawRect.x * fitScale).dp, y = (rawRect.y * fitScale).dp)
                            .size(
                                width = (rawRect.width * fitScale).coerceAtLeast(36.0).dp,
                                height = (rawRect.height * fitScale).coerceAtLeast(32.0).dp
                            )
                    ) {
                        MoodboardNodeCard(
                            node = node,
                            asset = node.referencedAssetId?.let { assetsById[it.uppercase()] },
                            thumbFileCache = thumbFileCache,
                            store = store,
                            renderScale = fitScale,
                            isSelected = selectedNodeId == node.id,
                            interactionEnabled = true,
                            onTap = { onSelectNode(node.id) },
                            onDoubleTap = { onDoubleTapNode(node) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FreeformCanvasStage(
    doc: MoodboardDocumentDto,
    assetsById: Map<String, AssetDto>,
    thumbFileCache: MutableMap<String, File>,
    store: CharkleAppStore,
    selectedNodeId: String?,
    connectingFromNodeId: String?,
    canvasOffsetX: Float,
    canvasOffsetY: Float,
    canvasZoom: Float,
    isDrawingInk: Boolean,
    activeInkHex: String,
    activeStrokePoints: List<InkStrokePointDto>,
    onTransformCanvas: (Offset, Offset, Float) -> Unit,
    onClearSelection: () -> Unit,
    onSelectNode: (String) -> Unit,
    onStartDragNode: (String) -> Unit,
    onDoubleTapNode: (BoardNodeDto) -> Unit,
    onMoveNode: (String, Double, Double) -> Unit,
    onResizeNode: (String, Double, Double) -> Unit,
    onInkDragStart: (Offset) -> Unit,
    onInkDragPoint: (Offset) -> Unit,
    onInkDragCancel: () -> Unit,
    onInkDragEnd: () -> Unit
) {
    val density = LocalDensity.current
    val isDark = LocalCharkleExtendedColors.current.isDark
    val dotColor = MaterialTheme.colorScheme.onBackground.copy(alpha = if (isDark) 0.16f else 0.13f)

    val latestOffsetX by rememberUpdatedState(canvasOffsetX)
    val latestOffsetY by rememberUpdatedState(canvasOffsetY)
    val latestZoom by rememberUpdatedState(canvasZoom)
    val latestOnTransform by rememberUpdatedState(onTransformCanvas)
    val latestOnClearSelection by rememberUpdatedState(onClearSelection)
    val latestOnInkStart by rememberUpdatedState(onInkDragStart)
    val latestOnInkPoint by rememberUpdatedState(onInkDragPoint)
    val latestOnInkCancel by rememberUpdatedState(onInkDragCancel)
    val latestOnInkEnd by rememberUpdatedState(onInkDragEnd)

    val nodesById = remember(doc.nodes) {
        doc.nodes.associateBy { it.id.uppercase() }
    }
    val groupNodes = remember(doc.nodes) {
        doc.nodes.filter { it.kind.groupFrame != null }.sortedBy { it.zIndex }
    }
    val foregroundNodes = remember(doc.nodes) {
        doc.nodes.filter { it.kind.groupFrame == null }.sortedBy { it.zIndex }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(isDrawingInk) {
                if (!isDrawingInk) {
                    detectTapGestures(onTap = { latestOnClearSelection() })
                }
            }
            .pointerInput(isDrawingInk) {
                if (!isDrawingInk) {
                    detectTransformGestures { centroid, pan, zoom, _ ->
                        latestOnTransform(centroid, pan, zoom)
                    }
                }
            }
            .pointerInput(isDrawingInk) {
                if (isDrawingInk) {
                    awaitEachGesture {
                        val firstDown = awaitFirstDown(requireUnconsumed = false)
                        val scalePx = (latestZoom * density.density).coerceAtLeast(0.001f)
                        var lastScreenPt = firstDown.position
                        var pointCount = 1
                        var switchedToMultiTouch = false
                        latestOnInkStart(
                            Offset(
                                x = (firstDown.position.x - latestOffsetX) / scalePx,
                                y = (firstDown.position.y - latestOffsetY) / scalePx
                            )
                        )
                        firstDown.consume()

                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break

                            if (pressed.size >= 2) {
                                if (!switchedToMultiTouch) {
                                    switchedToMultiTouch = true
                                    if (pointCount <= 3) {
                                        latestOnInkCancel()
                                    } else {
                                        latestOnInkEnd()
                                    }
                                }
                                val zoomChange = event.calculateZoom()
                                val panChange = event.calculatePan()
                                val centroid = event.calculateCentroid(useCurrent = false)
                                if (centroid != Offset.Unspecified) {
                                    latestOnTransform(centroid, panChange, zoomChange)
                                }
                                event.changes.forEach { it.consume() }
                                continue
                            }

                            if (switchedToMultiTouch) {
                                event.changes.forEach { it.consume() }
                                continue
                            }

                            val change = pressed.firstOrNull { it.id == firstDown.id } ?: break
                            change.consume()
                            val dist = (change.position - lastScreenPt).getDistance()
                            if (dist >= 2.5f) {
                                lastScreenPt = change.position
                                pointCount += 1
                                val curScalePx = (latestZoom * density.density).coerceAtLeast(0.001f)
                                latestOnInkPoint(
                                    Offset(
                                        x = (change.position.x - latestOffsetX) / curScalePx,
                                        y = (change.position.y - latestOffsetY) / curScalePx
                                    )
                                )
                            }
                        }

                        if (!switchedToMultiTouch) {
                            latestOnInkEnd()
                        }
                    }
                }
            }
    ) {
        // Calibrated studio dot grid (clear in both Light & Dark modes)
        Canvas(modifier = Modifier.fillMaxSize()) {
            val step = (28f * density.density * canvasZoom).coerceAtLeast(18f * density.density)
            val dotRadius = 1.45f * density.density * canvasZoom.coerceIn(0.75f, 1.35f)
            val startX = ((canvasOffsetX % step) + step) % step
            val startY = ((canvasOffsetY % step) + step) % step
            var y = startY
            while (y < size.height) {
                var x = startX
                while (x < size.width) {
                    drawCircle(color = dotColor, radius = dotRadius, center = Offset(x, y))
                    x += step
                }
                y += step
            }
        }

        // 1. Group frames behind everything
        groupNodes.forEach { node ->
            key(node.id) {
                PositionedFreeformNode(
                    node = node,
                    asset = null,
                    thumbFileCache = thumbFileCache,
                    store = store,
                    canvasOffsetX = canvasOffsetX,
                    canvasOffsetY = canvasOffsetY,
                    canvasZoom = canvasZoom,
                    isSelected = selectedNodeId == node.id || connectingFromNodeId == node.id,
                    isDrawingInk = isDrawingInk,
                    isConnectingMode = connectingFromNodeId != null,
                    onTap = { onSelectNode(node.id) },
                    onStartDrag = { onStartDragNode(node.id) },
                    onDoubleTap = { onDoubleTapNode(node) },
                    onMove = { dx, dy -> onMoveNode(node.id, dx, dy) },
                    onResize = { dw, dh -> onResizeNode(node.id, dw, dh) }
                )
            }
        }

        // 2. Connectors layer (supports curved, elbow, straight, anchors, dashes, arrows, and labels)
        if (doc.connectors.isNotEmpty()) {
            val defaultConnectorColor = if (isDark) Color(0xFF9AA6B5) else Color(0xFF5C6672)
            Canvas(modifier = Modifier.fillMaxSize()) {
                val scalePx = canvasZoom * density.density
                doc.connectors.forEach { conn ->
                    val fromNode = nodesById[conn.fromNodeId.uppercase()] ?: return@forEach
                    val toNode = nodesById[conn.toNodeId.uppercase()] ?: return@forEach
                    val (p1, dir1) = connectorEndpoint(fromNode, toNode, conn.fromAnchor, scalePx, canvasOffsetX, canvasOffsetY)
                    val (p2, dir2) = connectorEndpoint(toNode, fromNode, conn.toAnchor, scalePx, canvasOffsetX, canvasOffsetY)

                    val strokeWidth = (2.2f * scalePx).coerceIn(1.8f, 6f)
                    val color = if (conn.colorHex.equals("#5C6672", ignoreCase = true)) {
                        defaultConnectorColor
                    } else {
                        parseHexColor(conn.colorHex) ?: defaultConnectorColor
                    }

                    val path = Path().apply {
                        moveTo(p1.x, p1.y)
                        when (conn.style.lowercase()) {
                            "straight" -> lineTo(p2.x, p2.y)
                            "elbow" -> {
                                if (abs(dir1.x) >= abs(dir1.y)) {
                                    val midX = (p1.x + p2.x) * 0.5f
                                    lineTo(midX, p1.y)
                                    lineTo(midX, p2.y)
                                } else {
                                    val midY = (p1.y + p2.y) * 0.5f
                                    lineTo(p1.x, midY)
                                    lineTo(p2.x, midY)
                                }
                                lineTo(p2.x, p2.y)
                            }
                            else -> {
                                val dist = (p2 - p1).getDistance()
                                val handle = (dist * 0.36f).coerceIn(24f, 180f * canvasZoom.coerceAtLeast(0.5f))
                                val c1 = Offset(p1.x + dir1.x * handle, p1.y + dir1.y * handle)
                                val c2 = Offset(p2.x + dir2.x * handle, p2.y + dir2.y * handle)
                                cubicTo(c1.x, c1.y, c2.x, c2.y, p2.x, p2.y)
                            }
                        }
                    }

                    drawPath(
                        path = path,
                        color = color,
                        style = Stroke(
                            width = strokeWidth,
                            cap = StrokeCap.Round,
                            join = StrokeJoin.Round,
                            pathEffect = if (conn.dashed) PathEffect.dashPathEffect(floatArrayOf(12f, 8f)) else null
                        )
                    )

                    // Start anchor dot
                    drawCircle(color = color, radius = strokeWidth * 1.45f, center = p1)

                    // Directional arrowhead at target endpoint
                    val incomingAngle = when (conn.style.lowercase()) {
                        "straight" -> atan2((p2.y - p1.y).toDouble(), (p2.x - p1.x).toDouble())
                        else -> atan2((-dir2.y).toDouble(), (-dir2.x).toDouble())
                    }
                    val arrowLen = (8.5f * canvasZoom * density.density).coerceIn(7f, 18f)
                    val spread = Math.toRadians(28.0)
                    val wing1 = Offset(
                        x = p2.x - (arrowLen * cos(incomingAngle - spread)).toFloat(),
                        y = p2.y - (arrowLen * sin(incomingAngle - spread)).toFloat()
                    )
                    val wing2 = Offset(
                        x = p2.x - (arrowLen * cos(incomingAngle + spread)).toFloat(),
                        y = p2.y - (arrowLen * sin(incomingAngle + spread)).toFloat()
                    )
                    val arrowPath = Path().apply {
                        moveTo(wing1.x, wing1.y)
                        lineTo(p2.x, p2.y)
                        lineTo(wing2.x, wing2.y)
                    }
                    drawPath(
                        path = arrowPath,
                        color = color,
                        style = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round)
                    )
                }
            }

            // Optional text labels on connectors
            val scalePx = canvasZoom * density.density
            doc.connectors.forEach { conn ->
                val label = conn.label?.trim()?.takeIf { it.isNotEmpty() } ?: return@forEach
                val fromNode = nodesById[conn.fromNodeId.uppercase()] ?: return@forEach
                val toNode = nodesById[conn.toNodeId.uppercase()] ?: return@forEach
                val (p1, _) = connectorEndpoint(fromNode, toNode, conn.fromAnchor, scalePx, canvasOffsetX, canvasOffsetY)
                val (p2, _) = connectorEndpoint(toNode, fromNode, conn.toAnchor, scalePx, canvasOffsetX, canvasOffsetY)
                val midX = ((p1.x + p2.x) * 0.5f).roundToInt()
                val midY = ((p1.y + p2.y) * 0.5f).roundToInt()
                Surface(
                    shape = CircleShape,
                    color = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLowest,
                    shadowElevation = 2.dp,
                    modifier = Modifier
                        .offset { IntOffset(midX - 36, midY - 14) }
                        .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                ) {
                    Text(
                        text = label,
                        style = MaterialTheme.typography.labelSmall,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                    )
                }
            }
        }

        // 3. Asset cards, Sticky notes, Palette strips
        foregroundNodes.forEach { node ->
            key(node.id) {
                PositionedFreeformNode(
                    node = node,
                    asset = node.referencedAssetId?.let { assetsById[it.uppercase()] },
                    thumbFileCache = thumbFileCache,
                    store = store,
                    canvasOffsetX = canvasOffsetX,
                    canvasOffsetY = canvasOffsetY,
                    canvasZoom = canvasZoom,
                    isSelected = selectedNodeId == node.id || connectingFromNodeId == node.id,
                    isDrawingInk = isDrawingInk,
                    isConnectingMode = connectingFromNodeId != null,
                    onTap = { onSelectNode(node.id) },
                    onStartDrag = { onStartDragNode(node.id) },
                    onDoubleTap = { onDoubleTapNode(node) },
                    onMove = { dx, dy -> onMoveNode(node.id, dx, dy) },
                    onResize = { dw, dh -> onResizeNode(node.id, dw, dh) }
                )
            }
        }

        // 4. Persisted + Live Ink Strokes
        Canvas(modifier = Modifier.fillMaxSize()) {
            val scalePx = canvasZoom * density.density
            fun drawWorldStroke(points: List<InkStrokePointDto>, hex: String, width: Double, alpha: Double) {
                if (points.size < 2) return
                val path = Path()
                points.forEachIndexed { idx, pt ->
                    val sx = pt.x.toFloat() * scalePx + canvasOffsetX
                    val sy = pt.y.toFloat() * scalePx + canvasOffsetY
                    if (idx == 0) path.moveTo(sx, sy) else path.lineTo(sx, sy)
                }
                val strokeColor = (parseHexColor(hex) ?: Color(0xFF2A60E0)).copy(alpha = alpha.toFloat().coerceIn(0.1f, 1f))
                drawPath(
                    path = path,
                    color = strokeColor,
                    style = Stroke(
                        width = (width.toFloat() * scalePx).coerceAtLeast(2f),
                        cap = StrokeCap.Round,
                        join = StrokeJoin.Round
                    )
                )
            }
            doc.inkStrokes.forEach { s -> drawWorldStroke(s.points, s.colorHex, s.lineWidth, s.opacity) }
            if (activeStrokePoints.size >= 2) {
                drawWorldStroke(activeStrokePoints, activeInkHex, 3.5, 0.92)
            }
        }
    }
}

@Composable
private fun PositionedFreeformNode(
    node: BoardNodeDto,
    asset: AssetDto?,
    thumbFileCache: MutableMap<String, File>,
    store: CharkleAppStore,
    canvasOffsetX: Float,
    canvasOffsetY: Float,
    canvasZoom: Float,
    isSelected: Boolean,
    isDrawingInk: Boolean,
    isConnectingMode: Boolean,
    onTap: () -> Unit,
    onStartDrag: () -> Unit,
    onDoubleTap: () -> Unit,
    onMove: (Double, Double) -> Unit,
    onResize: (Double, Double) -> Unit
) {
    val density = LocalDensity.current
    val scalePx = canvasZoom * density.density
    val screenX = (node.frame.x.toFloat() * scalePx + canvasOffsetX).roundToInt()
    val screenY = (node.frame.y.toFloat() * scalePx + canvasOffsetY).roundToInt()
    val widthDp = (node.frame.width * canvasZoom).coerceAtLeast(36.0).dp
    val heightDp = (node.frame.height * canvasZoom).coerceAtLeast(32.0).dp

    val latestZoom by rememberUpdatedState(canvasZoom)
    val latestRotation by rememberUpdatedState(node.rotationDegrees)
    val latestOnStartDrag by rememberUpdatedState(onStartDrag)
    val latestOnMove by rememberUpdatedState(onMove)
    val latestOnResize by rememberUpdatedState(onResize)

    val canDragNode = !isDrawingInk && !isConnectingMode && !node.isLocked

    Box(
        modifier = Modifier
            .offset { IntOffset(screenX, screenY) }
            .size(width = widthDp, height = heightDp)
            .graphicsLayer {
                rotationZ = node.rotationDegrees.toFloat()
            }
            .pointerInput(node.id, canDragNode) {
                if (!canDragNode) return@pointerInput
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = true)
                    val slop = viewConfiguration.touchSlop
                    var accum = Offset.Zero
                    var dragStarted = false
                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break
                        // Yield immediately on multi-touch so 2-finger pinch/pan on canvas always wins
                        if (pressed.size > 1) break
                        val change = pressed.firstOrNull { it.id == down.id } ?: break
                        if (change.isConsumed) break
                        val localDelta = change.positionChange()
                        if (!dragStarted) {
                            accum += localDelta
                            if (accum.getDistance() >= slop) {
                                dragStarted = true
                                latestOnStartDrag()
                                change.consume()
                                val parentDelta = rotateLocalDeltaToParent(accum, latestRotation)
                                val curScalePx = (latestZoom * density.density).coerceAtLeast(0.001f)
                                latestOnMove(parentDelta.x.toDouble() / curScalePx, parentDelta.y.toDouble() / curScalePx)
                            }
                        } else if (localDelta != Offset.Zero) {
                            change.consume()
                            val parentDelta = rotateLocalDeltaToParent(localDelta, latestRotation)
                            val curScalePx = (latestZoom * density.density).coerceAtLeast(0.001f)
                            latestOnMove(parentDelta.x.toDouble() / curScalePx, parentDelta.y.toDouble() / curScalePx)
                        }
                    }
                }
            }
    ) {
        MoodboardNodeCard(
            node = node,
            asset = asset,
            thumbFileCache = thumbFileCache,
            store = store,
            renderScale = canvasZoom,
            isSelected = isSelected,
            interactionEnabled = !isDrawingInk,
            onTap = onTap,
            onDoubleTap = onDoubleTap
        )

        // Expanded 44dp touch target bottom-right resize handle when selected & unlocked
        if (isSelected && !node.isLocked && !isDrawingInk && !isConnectingMode) {
            Box(
                contentAlignment = Alignment.BottomEnd,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .size(44.dp)
                    .pointerInput(node.id) {
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = true)
                            down.consume()
                            while (true) {
                                val event = awaitPointerEvent()
                                val pressed = event.changes.filter { it.pressed }
                                if (pressed.size != 1) break
                                val change = pressed.firstOrNull { it.id == down.id } ?: break
                                val delta = change.positionChange()
                                if (delta != Offset.Zero) {
                                    change.consume()
                                    val curScalePx = (latestZoom * density.density).coerceAtLeast(0.001f)
                                    latestOnResize(delta.x.toDouble() / curScalePx, delta.y.toDouble() / curScalePx)
                                }
                            }
                        }
                    }
            ) {
                Box(
                    modifier = Modifier
                        .padding(2.dp)
                        .size(22.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary)
                        .border(2.dp, Color.White, CircleShape)
                )
            }
        }
    }
}

@Composable
private fun MoodboardNodeCard(
    node: BoardNodeDto,
    asset: AssetDto?,
    thumbFileCache: MutableMap<String, File>,
    store: CharkleAppStore,
    renderScale: Float,
    isSelected: Boolean,
    interactionEnabled: Boolean,
    onTap: () -> Unit,
    onDoubleTap: () -> Unit
) {
    val isDark = LocalCharkleExtendedColors.current.isDark
    val density = LocalDensity.current
    val visualScale = renderScale.coerceIn(0.30f, 2.50f)
    val borderColor = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant
    val borderWidth = if (isSelected) 2.dp else 0.6.dp
    val latestOnTap by rememberUpdatedState(onTap)
    val latestOnDoubleTap by rememberUpdatedState(onDoubleTap)

    val tapModifier = if (interactionEnabled) {
        Modifier.pointerInput(node.id) {
            detectTapGestures(
                onTap = { latestOnTap() },
                onDoubleTap = { latestOnDoubleTap() }
            )
        }
    } else {
        Modifier
    }

    Box(modifier = Modifier.fillMaxSize()) {
        when {
            node.kind.assetRef != null -> {
                val assetId = node.kind.assetRef.assetId
                val cacheKey = assetId.uppercase()
                var file by remember(cacheKey) { mutableStateOf(thumbFileCache[cacheKey]) }
                LaunchedEffect(cacheKey) {
                    if (file == null) {
                        val resolved = withContext(Dispatchers.IO) {
                            store.thumbnailFile(assetId, previewTier = true)
                                ?: store.thumbnailFile(assetId, previewTier = false)
                        }
                        if (resolved != null) {
                            thumbFileCache[cacheKey] = resolved
                            file = resolved
                        }
                    }
                }
                val cardShape = RoundedCornerShape((12f * visualScale).coerceIn(5f, 16f).dp)
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(cardShape)
                        .background(MaterialTheme.colorScheme.surfaceContainer)
                        .border(borderWidth, borderColor, cardShape)
                        .then(tapModifier),
                    contentAlignment = Alignment.Center
                ) {
                    if (file != null) {
                        AsyncImage(
                            model = file,
                            contentDescription = asset?.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .fillMaxSize()
                                .graphicsLayer {
                                    scaleX = if (node.flipHorizontal) -1f else 1f
                                    scaleY = if (node.flipVertical) -1f else 1f
                                }
                        )
                    } else {
                        val assetTitle = asset?.title?.takeIf { it.isNotBlank() }
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.padding((10f * visualScale).coerceIn(4f, 14f).dp)
                        ) {
                            Icon(
                                Icons.Rounded.Image,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                modifier = Modifier.size((24f * visualScale).coerceIn(14f, 30f).dp)
                            )
                            if (assetTitle != null) {
                                Text(
                                    text = assetTitle,
                                    style = MaterialTheme.typography.labelSmall.copy(
                                        fontSize = (11f * visualScale).coerceIn(6.5f, 16f).sp,
                                        lineHeight = (14f * visualScale).coerceIn(8.5f, 20f).sp
                                    ),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                }
            }
            node.kind.note != null -> {
                val note = node.kind.note
                val palette = resolveNotePalette(note.style, isDark)
                val noteBorderColor = if (isSelected) MaterialTheme.colorScheme.primary else palette.border
                val noteBorderWidth = if (isSelected) 2.dp else 1.dp
                val noteShape = RoundedCornerShape((14f * visualScale).coerceIn(6f, 22f).dp)
                val padDp = (12f * visualScale).coerceIn(4f, 18f)
                val gapDp = (4f * visualScale).coerceIn(1.5f, 6f)
                val baseBodySp = note.fontSize.toFloat().coerceIn(11f, 24f)
                val titleFontSp = (baseBodySp * visualScale).coerceIn(6.5f, 32f)
                val titleLineSp = titleFontSp * 1.30f
                val bodyFontSp = (baseBodySp * 0.88f * visualScale).coerceIn(5.8f, 28f)
                val bodyLineSp = bodyFontSp * 1.34f
                val fontScale = density.fontScale.coerceAtLeast(1f)
                val noteTitle = note.title?.takeIf { it.isNotBlank() }

                Surface(
                    shape = noteShape,
                    color = palette.background,
                    shadowElevation = if (isDark) 4.dp else 2.dp,
                    modifier = Modifier
                        .fillMaxSize()
                        .border(noteBorderWidth, noteBorderColor, noteShape)
                        .then(tapModifier)
                ) {
                    BoxWithConstraints(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(padDp.dp)
                    ) {
                        val availHeightDp = maxHeight.value
                        val hasBody = note.text.isNotBlank()
                        val titleLineDp = titleLineSp * fontScale
                        val bodyLineDp = bodyLineSp * fontScale
                        val maxTitleLines = when {
                            noteTitle == null -> 0
                            hasBody && availHeightDp < titleLineDp * 3.2f -> 1
                            availHeightDp < titleLineDp * 2.1f -> 1
                            else -> 2
                        }
                        val reservedTitleDp = if (noteTitle != null) {
                            val approxCharDp = (titleFontSp * 1.05f * fontScale).coerceAtLeast(1f)
                            val estTitleLines = if (maxTitleLines == 1 || maxWidth.value <= 1f) {
                                1
                            } else {
                                val charsPerLine = (maxWidth.value / approxCharDp).coerceAtLeast(1f)
                                if (noteTitle.length > charsPerLine * 0.88f) 2 else 1
                            }
                            estTitleLines * titleLineDp + if (hasBody) gapDp else 0f
                        } else {
                            0f
                        }
                        val remainingForBodyDp = (availHeightDp - reservedTitleDp - 1.5f).coerceAtLeast(0f)
                        val maxBodyLines = if (hasBody && bodyLineDp > 0.1f) {
                            (remainingForBodyDp / bodyLineDp).toInt().coerceAtLeast(0)
                        } else {
                            0
                        }

                        Column(verticalArrangement = Arrangement.spacedBy(gapDp.dp)) {
                            if (noteTitle != null && maxTitleLines > 0) {
                                Text(
                                    text = noteTitle,
                                    color = palette.foreground,
                                    style = MaterialTheme.typography.titleSmall.copy(
                                        fontWeight = FontWeight.SemiBold,
                                        fontSize = titleFontSp.sp,
                                        lineHeight = titleLineSp.sp
                                    ),
                                    maxLines = maxTitleLines,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                            if (hasBody && maxBodyLines > 0) {
                                Text(
                                    text = note.text,
                                    color = palette.foreground.copy(alpha = 0.90f),
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        fontSize = bodyFontSp.sp,
                                        lineHeight = bodyLineSp.sp
                                    ),
                                    maxLines = maxBodyLines,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                }
            }
            node.kind.groupFrame != null -> {
                val group = node.kind.groupFrame
                val tint = resolveGroupTintColor(group.tint)
                val fillAlpha = if (isDark) 0.18f else 0.13f
                val strokeAlpha = if (isDark) 0.70f else 0.55f
                val pillAlpha = if (isDark) 0.34f else 0.24f
                val groupShape = RoundedCornerShape((18f * visualScale).coerceIn(8f, 24f).dp)
                val pillOuterPad = (10f * visualScale).coerceIn(3f, 12f).dp
                val pillHorizPad = (10f * visualScale).coerceIn(5f, 12f).dp
                val pillVertPad = (4f * visualScale).coerceIn(1.5f, 5f).dp
                val pillFontSp = (12f * visualScale).coerceIn(7f, 20f)
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(groupShape)
                        .background(tint.copy(alpha = fillAlpha))
                        .border(
                            width = if (isSelected) 2.dp else 1.25.dp,
                            color = if (isSelected) MaterialTheme.colorScheme.primary else tint.copy(alpha = strokeAlpha),
                            shape = groupShape
                        )
                        .then(tapModifier)
                ) {
                    Surface(
                        shape = CircleShape,
                        color = tint.copy(alpha = pillAlpha),
                        contentColor = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(pillOuterPad)
                    ) {
                        Text(
                            text = group.title.ifBlank { "分组" },
                            style = MaterialTheme.typography.labelMedium.copy(
                                fontWeight = FontWeight.SemiBold,
                                fontSize = pillFontSp.sp,
                                lineHeight = (pillFontSp * 1.3f).sp
                            ),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(horizontal = pillHorizPad, vertical = pillVertPad)
                        )
                    }
                }
            }
            node.kind.paletteStrip != null -> {
                val colors = node.kind.paletteStrip.colors
                val stripShape = RoundedCornerShape((12f * visualScale).coerceIn(5f, 16f).dp)
                val swatchShape = RoundedCornerShape((8f * visualScale).coerceIn(3f, 10f).dp)
                val stripPad = (6f * visualScale).coerceIn(2.5f, 8f).dp
                Surface(
                    shape = stripShape,
                    color = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLowest,
                    modifier = Modifier
                        .fillMaxSize()
                        .border(borderWidth, borderColor, stripShape)
                        .then(tapModifier)
                ) {
                    Row(
                        modifier = Modifier.fillMaxSize().padding(stripPad),
                        horizontalArrangement = Arrangement.spacedBy((4f * visualScale).coerceIn(2f, 6f).dp)
                    ) {
                        colors.take(6).forEach { swatch ->
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .fillMaxSize()
                                    .clip(swatchShape)
                                    .background(parseHexColor(swatch.hex) ?: Color.Gray)
                                    .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, swatchShape)
                            )
                        }
                    }
                }
            }
        }

        if (node.isLocked) {
            Icon(
                Icons.Rounded.Lock,
                contentDescription = "已锁定",
                tint = Color.White,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding((6f * visualScale).coerceIn(2.5f, 8f).dp)
                    .size((18f * visualScale).coerceIn(12f, 22f).dp)
                    .background(Color.Black.copy(alpha = 0.62f), CircleShape)
                    .padding((3f * visualScale).coerceIn(2f, 4f).dp)
            )
        }
    }
}

@Composable
private fun SelectedNodeFloatingPill(
    node: BoardNodeDto,
    isFreeform: Boolean,
    hasConnectors: Boolean,
    onOpenAsset: () -> Unit,
    onRevealInLibrary: () -> Unit,
    onEditNote: () -> Unit,
    onEditGroup: () -> Unit,
    onStartConnect: () -> Unit,
    onClearConnectors: () -> Unit,
    onRotate: () -> Unit,
    onFlipH: () -> Unit,
    onToggleLock: () -> Unit,
    onBringToFront: () -> Unit,
    onDelete: () -> Unit
) {
    val actions = buildList {
        if (node.kind.assetRef != null) {
            add(ConnectedActionItem(Icons.Rounded.Visibility, "预览原图", onClick = onOpenAsset))
            add(ConnectedActionItem(Icons.Rounded.MyLocation, "在素材库中定位", onClick = onRevealInLibrary))
            if (!node.isLocked) {
                add(ConnectedActionItem(Icons.AutoMirrored.Rounded.RotateRight, "旋转 15°", onClick = onRotate))
                add(ConnectedActionItem(Icons.Rounded.Flip, "水平翻转", onClick = onFlipH))
            }
        } else if (node.kind.note != null) {
            if (!node.isLocked) {
                add(ConnectedActionItem(Icons.Rounded.Edit, "编辑便签", onClick = onEditNote))
                if (isFreeform) {
                    add(ConnectedActionItem(Icons.AutoMirrored.Rounded.RotateRight, "旋转 15°", onClick = onRotate))
                }
            }
        } else if (node.kind.groupFrame != null) {
            if (!node.isLocked) {
                add(ConnectedActionItem(Icons.Rounded.Edit, "编辑分组", onClick = onEditGroup))
            }
        }
        if (isFreeform) {
            add(ConnectedActionItem(Icons.Rounded.Link, "连接其他元素", onClick = onStartConnect))
            if (hasConnectors) {
                add(ConnectedActionItem(Icons.Rounded.LinkOff, "断开全部连线", onClick = onClearConnectors))
            }
            add(ConnectedActionItem(Icons.Rounded.FlipToFront, "置顶层级", onClick = onBringToFront))
        }
        add(
            ConnectedActionItem(
                icon = if (node.isLocked) Icons.Rounded.Lock else Icons.Rounded.LockOpen,
                contentDescription = if (node.isLocked) "解锁元素" else "锁定元素",
                checked = node.isLocked,
                onClick = onToggleLock
            )
        )
        if (!node.isLocked) {
            add(ConnectedActionItem(Icons.Rounded.DeleteOutline, "从画布移除", onClick = onDelete))
        }
    }

    Box(modifier = Modifier.horizontalScroll(rememberScrollState())) {
        CharkleConnectedButtonGroup(
            items = actions,
            height = 42.dp
        )
    }
}

@Composable
private fun StudioDockButton(
    icon: ImageVector,
    label: String,
    active: Boolean,
    onClick: () -> Unit
) {
    val bg = if (active) MaterialTheme.colorScheme.primary else Color.Transparent
    val fg = if (active) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    Surface(
        shape = CircleShape,
        color = bg,
        contentColor = fg,
        modifier = Modifier
            .clip(CircleShape)
            .clickable(onClick = onClick)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(icon, contentDescription = label, modifier = Modifier.size(18.dp))
            Text(label, style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp), maxLines = 1)
        }
    }
}

@Composable
private fun MoodboardAssetPickerSheet(
    assets: List<AssetDto>,
    isLoading: Boolean,
    existingBoardAssetIds: Set<String>,
    thumbFileCache: MutableMap<String, File>,
    store: CharkleAppStore,
    onConfirm: (List<AssetDto>) -> Unit
) {
    var selectedIds by remember { mutableStateOf(emptySet<String>()) }
    var searchQuery by remember { mutableStateOf("") }

    val filteredAssets = remember(assets, searchQuery) {
        val q = searchQuery.trim()
        if (q.isEmpty()) assets
        else assets.filter { a ->
            a.title.contains(q, ignoreCase = true) ||
                a.tags.any { it.contains(q, ignoreCase = true) } ||
                a.notes.contains(q, ignoreCase = true)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("选择素材加入情绪板", style = MaterialTheme.typography.titleLarge)
            Button(
                onClick = { onConfirm(assets.filter { it.id in selectedIds }) },
                enabled = selectedIds.isNotEmpty(),
                shape = CircleShape
            ) {
                Text("添加 (${selectedIds.size})")
            }
        }

        if (assets.size > 6) {
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("搜索素材标题或标签…") },
                leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null, modifier = Modifier.size(18.dp)) },
                trailingIcon = if (searchQuery.isNotEmpty()) {
                    {
                        IconButton(onClick = { searchQuery = "" }) {
                            Icon(Icons.Rounded.Close, contentDescription = "清空搜索", modifier = Modifier.size(18.dp))
                        }
                    }
                } else null,
                singleLine = true,
                shape = CircleShape,
                modifier = Modifier.fillMaxWidth()
            )
        }

        when {
            isLoading && assets.isEmpty() -> {
                Box(Modifier.fillMaxWidth().height(260.dp), contentAlignment = Alignment.Center) {
                    LoadingIndicator()
                }
            }
            filteredAssets.isEmpty() -> {
                Box(Modifier.fillMaxWidth().height(220.dp), contentAlignment = Alignment.Center) {
                    Text(
                        text = if (assets.isEmpty()) "素材库暂无可添加素材，请先采集灵感。" else "没有匹配的素材",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            else -> {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    contentPadding = PaddingValues(bottom = 24.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.height(400.dp)
                ) {
                    items(filteredAssets, key = { it.id }) { asset ->
                        val picked = asset.id in selectedIds
                        val alreadyOnBoard = asset.id.uppercase() in existingBoardAssetIds
                        val cacheKey = asset.id.uppercase()
                        var thumb by remember(cacheKey) { mutableStateOf(thumbFileCache[cacheKey]) }
                        LaunchedEffect(cacheKey) {
                            if (thumb == null) {
                                val resolved = withContext(Dispatchers.IO) { store.thumbnailFile(asset.id) }
                                if (resolved != null) {
                                    thumbFileCache[cacheKey] = resolved
                                    thumb = resolved
                                }
                            }
                        }

                        Box(
                            modifier = Modifier
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(14.dp))
                                .background(MaterialTheme.colorScheme.surfaceContainer)
                                .border(
                                    width = if (picked) 2.5.dp else 0.5.dp,
                                    color = if (picked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                                    shape = RoundedCornerShape(14.dp)
                                )
                                .clickable {
                                    selectedIds = if (picked) selectedIds - asset.id else selectedIds + asset.id
                                }
                        ) {
                            if (thumb != null) {
                                AsyncImage(
                                    model = thumb,
                                    contentDescription = asset.title,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize()
                                )
                            }
                            if (alreadyOnBoard && !picked) {
                                Surface(
                                    shape = CircleShape,
                                    color = Color.Black.copy(alpha = 0.62f),
                                    modifier = Modifier.align(Alignment.TopStart).padding(6.dp)
                                ) {
                                    Text(
                                        text = "已在板内",
                                        color = Color.White,
                                        style = MaterialTheme.typography.labelSmall,
                                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                    )
                                }
                            }
                            if (picked) {
                                Surface(
                                    shape = CircleShape,
                                    color = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.align(Alignment.TopEnd).padding(6.dp)
                                ) {
                                    Icon(
                                        Icons.Rounded.Check,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onPrimary,
                                        modifier = Modifier.padding(4.dp).size(14.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

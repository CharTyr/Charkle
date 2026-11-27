@file:OptIn(
    ExperimentalMaterial3Api::class,
    ExperimentalMaterial3ExpressiveApi::class,
    ExperimentalSerializationApi::class
)

package com.charkle.android.ui.pinterest

import android.annotation.SuppressLint
import android.content.Intent
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CenterFocusStrong
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.FolderCopy
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.ShoppingBag
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.net.toUri
import coil3.compose.AsyncImage
import com.charkle.android.core.PinterestAccountDto
import com.charkle.android.core.PinterestBoardDto
import com.charkle.android.core.PinterestPinDetailResultDto
import com.charkle.android.core.PinterestPinDto
import com.charkle.android.core.PinterestSpatialCardDto
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.CharkleWavyProgress
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.math.roundToInt

private val PinterestWireJson = Json {
    encodeDefaults = true
    explicitNulls = false
    ignoreUnknownKeys = true
}

private data class SpatialWorldBounds(
    val minX: Float,
    val maxX: Float,
    val minY: Float,
    val maxY: Float
)

private sealed interface PinterestSourceUi {
    val label: String
    fun toWireJson(): String

    data object Home : PinterestSourceUi {
        override val label = "主页推荐"
        override fun toWireJson(): String = """{"kind":"home"}"""
    }

    data class Search(val query: String) : PinterestSourceUi {
        override val label get() = "搜索：$query"
        override fun toWireJson(): String = buildJsonObject {
            put("kind", "search")
            put("query", query)
        }.toString()
    }

    data class Board(val board: PinterestBoardDto) : PinterestSourceUi {
        override val label get() = "画板：${board.name}"
        override fun toWireJson(): String {
            val boardJson = PinterestWireJson.encodeToString(board)
            return """{"kind":"board","board":$boardJson}"""
        }
    }

    data class Similar(val seedPin: PinterestPinDto) : PinterestSourceUi {
        override val label get() = "相似灵感"
        override fun toWireJson(): String {
            val pinJson = PinterestWireJson.encodeToString(seedPin)
            return """{"kind":"similar","seedPin":$pinJson}"""
        }
    }
}

private fun readPinterestCookieHeader(extraUrls: List<String> = emptyList()): String = runCatching {
    val cm = CookieManager.getInstance()
    cm.flush()
    val merged = LinkedHashMap<String, Pair<String, String>>()
    val candidateUrls = buildList {
        extraUrls.forEach { rawUrl ->
            val trimmed = rawUrl.trim()
            if (trimmed.startsWith("https://", ignoreCase = true) && trimmed.contains("pinterest.", ignoreCase = true)) {
                add(trimmed)
            }
        }
        add("https://www.pinterest.com/")
        add("https://pinterest.com/")
        add("https://m.pinterest.com/")
    }.distinct()

    for (url in candidateUrls) {
        val raw = cm.getCookie(url).orEmpty()
        if (raw.isBlank()) continue
        raw.split(';').forEach { segment ->
            val eqIdx = segment.indexOf('=')
            if (eqIdx <= 0) return@forEach
            val key = segment.substring(0, eqIdx).trim()
            val value = segment.substring(eqIdx + 1).trim()
            if (key.isEmpty()) return@forEach
            val norm = key.lowercase()
            val existing = merged[norm]
            if (existing == null || (existing.second.isEmpty() && value.isNotEmpty())) {
                merged[norm] = key to value
            }
        }
    }

    merged.values
        .filter { (_, v) -> v.isNotEmpty() }
        .joinToString("; ") { (k, v) -> "$k=$v" }
}.getOrDefault("")

private fun tearDownWebViewSafely(view: WebView) {
    runCatching {
        view.stopLoading()
        view.onPause()
        view.webViewClient = WebViewClient()
        view.webChromeClient = null
        (view.parent as? ViewGroup)?.removeView(view)
        view.removeAllViews()
        view.destroy()
    }
}

@Composable
fun PinterestExploreScreen(
    state: CharkleUiState,
    store: CharkleAppStore,
    onClose: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val isDark = LocalCharkleExtendedColors.current.isDark
    val floatingSurface = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.94f)
    } else {
        MaterialTheme.colorScheme.surfaceContainerLowest.copy(alpha = 0.94f)
    }

    var isCheckingSession by remember { mutableStateOf(true) }
    var account by remember { mutableStateOf<PinterestAccountDto?>(null) }
    var showLoginWebView by remember { mutableStateOf(false) }
    var lastLoginHostUrl by remember { mutableStateOf<String?>(null) }
    var autoLoginCheckJob by remember { mutableStateOf<Job?>(null) }

    var source by remember { mutableStateOf<PinterestSourceUi>(PinterestSourceUi.Home) }
    var pins by remember { mutableStateOf<List<PinterestPinDto>>(emptyList()) }
    var cards by remember { mutableStateOf<List<PinterestSpatialCardDto>>(emptyList()) }
    var nextBookmark by remember { mutableStateOf<String?>(null) }
    var hasMore by remember { mutableStateOf(false) }
    var isLoadingFeed by remember { mutableStateOf(false) }
    var isLoadingMore by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var loadMoreError by remember { mutableStateOf<String?>(null) }
    var feedSessionToken by remember { mutableIntStateOf(0) }
    var feedJob by remember { mutableStateOf<Job?>(null) }
    var loadMoreJob by remember { mutableStateOf<Job?>(null) }

    var boards by remember { mutableStateOf<List<PinterestBoardDto>>(emptyList()) }
    var isRefreshingBoards by remember { mutableStateOf(false) }
    var importedPinIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var trayPins by remember { mutableStateOf<List<PinterestPinDto>>(emptyList()) }
    var fastPickMode by remember { mutableStateOf(false) }
    var preferredImportFolderId by remember { mutableStateOf<String?>(null) }

    var showSearchBar by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }
    var showSourceMenu by remember { mutableStateOf(false) }
    var showAccountMenu by remember { mutableStateOf(false) }
    var showTraySheet by remember { mutableStateOf(false) }
    var showBoardImportSheet by remember { mutableStateOf(false) }

    // Drill-down back stack for Pin detail + similar pins exploration
    var pinDetailStack by remember { mutableStateOf<List<PinterestPinDto>>(emptyList()) }
    val activeDetailPin = pinDetailStack.lastOrNull()
    val pinDetailCache = remember { mutableStateMapOf<String, PinterestPinDetailResultDto>() }
    var pinDetailResult by remember { mutableStateOf<PinterestPinDetailResultDto?>(null) }
    var pinDetailError by remember { mutableStateOf<String?>(null) }
    var isLoadingDetail by remember { mutableStateOf(false) }
    var detailRetryTick by remember { mutableIntStateOf(0) }

    var isImporting by remember { mutableStateOf(false) }
    var importProgressLabel by remember { mutableStateOf<String?>(null) }

    var cameraOffsetX by remember { mutableFloatStateOf(0f) }
    var cameraOffsetY by remember { mutableFloatStateOf(0f) }
    var cameraScale by remember { mutableFloatStateOf(0.76f) }
    var viewportWidthPx by remember { mutableFloatStateOf(0f) }
    var viewportHeightPx by remember { mutableFloatStateOf(0f) }
    var initializedCamera by remember { mutableStateOf(false) }

    BackHandler {
        when {
            showSearchBar -> showSearchBar = false
            else -> onClose()
        }
    }

    fun currentCookieHeader(): String = readPinterestCookieHeader(listOfNotNull(lastLoginHostUrl))

    fun recenterCamera() {
        if (viewportWidthPx > 0f && viewportHeightPx > 0f) {
            cameraScale = 0.76f
            cameraOffsetX = viewportWidthPx * 0.5f
            cameraOffsetY = viewportHeightPx * 0.5f
        }
    }

    fun toggleTray(pin: PinterestPinDto) {
        val exists = trayPins.any { it.id == pin.id }
        trayPins = if (exists) trayPins.filterNot { it.id == pin.id } else trayPins + pin
        store.showToast(if (exists) "已从托盘移出" else "已加入托盘（共 ${trayPins.size} 项）")
    }

    suspend fun refreshImportedPinIds() {
        importedPinIds = runCatching { store.repository.pinterestExistingImportedPinIds() }
            .getOrDefault(importedPinIds)
    }

    fun launchFreshFeed(targetSource: PinterestSourceUi) {
        feedJob?.cancel()
        loadMoreJob?.cancel()
        loadMoreJob = null
        val token = feedSessionToken + 1
        feedSessionToken = token

        source = targetSource
        isLoadingFeed = true
        isLoadingMore = false
        errorMessage = null
        loadMoreError = null
        pins = emptyList()
        cards = emptyList()
        nextBookmark = null
        hasMore = false
        recenterCamera()

        feedJob = scope.launch {
            try {
                val page = store.repository.pinterestFetchFeed(
                    cookieHeader = currentCookieHeader(),
                    sourceJson = targetSource.toWireJson(),
                    bookmark = null,
                    pageSize = 28
                )
                if (token != feedSessionToken) return@launch
                pins = page.pins
                nextBookmark = page.nextBookmark
                hasMore = page.hasMore && !page.nextBookmark.isNullOrBlank()
                cards = runCatching {
                    store.repository.pinterestComputeSpatialLayout(page.pins, 224.0, 16.0)
                }.getOrDefault(emptyList())
            } catch (e: CancellationException) {
                throw e
            } catch (err: Exception) {
                if (token == feedSessionToken) {
                    errorMessage = err.message ?: "无法加载 Pinterest 灵感流"
                }
            } finally {
                if (token == feedSessionToken) {
                    isLoadingFeed = false
                }
            }
        }
    }

    fun launchAppendFeed(forceRetry: Boolean = false) {
        if (isLoadingFeed || isLoadingMore || loadMoreJob?.isActive == true) return
        if (!forceRetry && loadMoreError != null) return
        val usedBookmark = nextBookmark?.takeIf { it.isNotBlank() } ?: return
        if (!hasMore) return

        val token = feedSessionToken
        val activeSource = source
        isLoadingMore = true
        loadMoreError = null

        loadMoreJob = scope.launch {
            try {
                val page = store.repository.pinterestFetchFeed(
                    cookieHeader = currentCookieHeader(),
                    sourceJson = activeSource.toWireJson(),
                    bookmark = usedBookmark,
                    pageSize = 28
                )
                if (token != feedSessionToken) return@launch

                val existing = pins.map { it.id }.toHashSet()
                val addedPins = page.pins.filter { existing.add(it.id) }
                val merged = pins + addedPins
                val nextBm = page.nextBookmark?.takeIf { it.isNotBlank() && it != usedBookmark }

                pins = merged
                nextBookmark = nextBm
                hasMore = page.hasMore && nextBm != null && addedPins.isNotEmpty()
                if (addedPins.isNotEmpty()) {
                    val computed = runCatching {
                        store.repository.pinterestComputeSpatialLayout(merged, 224.0, 16.0)
                    }.getOrNull()
                    if (computed != null) {
                        cards = computed
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (err: Exception) {
                if (token == feedSessionToken) {
                    loadMoreError = err.message ?: "加载更多灵感失败"
                }
            } finally {
                if (token == feedSessionToken) {
                    isLoadingMore = false
                }
            }
        }
    }

    suspend fun refreshUserBoards(targetAccount: PinterestAccountDto? = account) {
        val username = targetAccount?.username?.trim().orEmpty()
        if (username.isEmpty()) return
        isRefreshingBoards = true
        try {
            boards = runCatching {
                store.repository.pinterestFetchUserBoards(currentCookieHeader(), username)
            }.getOrDefault(boards)
        } finally {
            isRefreshingBoards = false
        }
    }

    suspend fun verifySessionAndBootstrap() {
        isCheckingSession = true
        refreshImportedPinIds()
        val cookie = currentCookieHeader()
        val acc = runCatching { store.repository.pinterestCheckSession(cookie) }.getOrNull()
        account = acc
        isCheckingSession = false
        if (acc != null) {
            launchFreshFeed(PinterestSourceUi.Home)
            if (acc.username.isNotBlank()) {
                refreshUserBoards(acc)
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            feedJob?.cancel()
            loadMoreJob?.cancel()
            autoLoginCheckJob?.cancel()
        }
    }

    LaunchedEffect(Unit) {
        verifySessionAndBootstrap()
    }

    LaunchedEffect(activeDetailPin?.id, detailRetryTick) {
        val pin = activeDetailPin ?: return@LaunchedEffect
        val cached = pinDetailCache[pin.id]
        if (cached != null) {
            pinDetailResult = cached
            pinDetailError = null
            isLoadingDetail = false
            return@LaunchedEffect
        }
        isLoadingDetail = true
        pinDetailResult = null
        pinDetailError = null
        runCatching {
            store.repository.pinterestFetchPinDetail(currentCookieHeader(), pin)
        }.onSuccess { result ->
            if (pinDetailCache.size >= 40) {
                pinDetailCache.keys.firstOrNull()?.let { pinDetailCache.remove(it) }
            }
            pinDetailCache[pin.id] = result
            pinDetailResult = result
        }.onFailure { err ->
            pinDetailError = err.message ?: "获取详情与相似灵感失败"
        }
        isLoadingDetail = false
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        when {
            isCheckingSession -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        LoadingIndicator()
                        Spacer(Modifier.height(10.dp))
                        Text("正在检查 Pinterest 登录状态…", style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
            account == null -> {
                // Signed-out M3 Expressive Welcome Stage
                val cookieShape = MaterialShapes.Cookie9Sided.toShape()
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .statusBarsPadding()
                        .navigationBarsPadding()
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        FilledTonalButton(onClick = onClose, shape = CircleShape) {
                            Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("返回库内")
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    Surface(
                        shape = RoundedCornerShape(28.dp),
                        color = if (isDark) MaterialTheme.colorScheme.surfaceContainer else MaterialTheme.colorScheme.surfaceContainerLowest,
                        tonalElevation = 2.dp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(28.dp))
                    ) {
                        Column(
                            modifier = Modifier.padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            Surface(
                                shape = cookieShape,
                                color = MaterialTheme.colorScheme.primaryContainer,
                                modifier = Modifier.size(88.dp)
                            ) {
                                Box(contentAlignment = Alignment.Center) {
                                    Icon(
                                        Icons.Rounded.Explore,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                                        modifier = Modifier.size(38.dp)
                                    )
                                }
                            }
                            Text(
                                text = "Pinterest 无限二维灵感空间",
                                style = MaterialTheme.typography.headlineMedium,
                                textAlign = TextAlign.Center
                            )
                            Text(
                                text = "四象限无限平移与双指缩放浏览、快选模式一键收集进托盘、点击 Pin 逐层探索相似灵感，以及按画板自动建目录批量导入你的收藏。",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                WelcomeFeatureBadge(Icons.Rounded.Explore, "无限空间", Modifier.weight(1f))
                                WelcomeFeatureBadge(Icons.Rounded.ShoppingBag, "托盘快选", Modifier.weight(1f))
                                WelcomeFeatureBadge(Icons.Rounded.FolderCopy, "画板导入", Modifier.weight(1f))
                            }
                            Spacer(Modifier.height(4.dp))
                            Button(
                                onClick = { showLoginWebView = true },
                                shape = RoundedCornerShape(20.dp),
                                modifier = Modifier.fillMaxWidth().height(54.dp)
                            ) {
                                Text("登录 Pinterest 账号", style = MaterialTheme.typography.titleSmall)
                            }
                            Text(
                                text = "登录验证完全在可见系统 WebView 中由你亲自完成，登录态仅保留在本机，随时可在右上角退出清除。",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center
                            )
                        }
                    }
                    Spacer(Modifier.weight(1.2f))
                }
            }
            else -> {
                // Signed-In Full-Bleed Infinite 2D Spatial Canvas
                BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                    val vpWidthPx = with(density) { maxWidth.toPx() }
                    val vpHeightPx = with(density) { maxHeight.toPx() }

                    LaunchedEffect(vpWidthPx, vpHeightPx) {
                        viewportWidthPx = vpWidthPx
                        viewportHeightPx = vpHeightPx
                        if (!initializedCamera && vpWidthPx > 0f && vpHeightPx > 0f) {
                            cameraOffsetX = vpWidthPx * 0.5f
                            cameraOffsetY = vpHeightPx * 0.5f
                            initializedCamera = true
                        }
                    }

                    val scalePx = cameraScale * density.density
                    val trayPinIds = remember(trayPins) { trayPins.map { it.id }.toHashSet() }
                    val worldBounds = remember(cards) {
                        if (cards.isEmpty()) null
                        else SpatialWorldBounds(
                            minX = cards.minOf { it.frame.x }.toFloat(),
                            maxX = cards.maxOf { it.frame.x + it.frame.width }.toFloat(),
                            minY = cards.minOf { it.frame.y }.toFloat(),
                            maxY = cards.maxOf { it.frame.y + it.frame.height }.toFloat()
                        )
                    }
                    val latestWorldBounds by rememberUpdatedState(worldBounds)

                    val visibleCards = remember(cards, cameraOffsetX, cameraOffsetY, cameraScale, vpWidthPx, vpHeightPx) {
                        val overscan = 320f
                        cards.filter { card ->
                            val left = card.frame.x.toFloat() * scalePx + cameraOffsetX
                            val top = card.frame.y.toFloat() * scalePx + cameraOffsetY
                            val right = left + card.frame.width.toFloat() * scalePx
                            val bottom = top + card.frame.height.toFloat() * scalePx
                            right >= -overscan && left <= vpWidthPx + overscan &&
                                bottom >= -overscan && top <= vpHeightPx + overscan
                        }
                    }

                    // Debounced non-cancelling edge auto-pagination with backoff on error
                    LaunchedEffect(feedSessionToken) {
                        snapshotFlow {
                            val bounds = latestWorldBounds
                            if (bounds == null || !hasMore || isLoadingFeed || isLoadingMore || loadMoreError != null) {
                                false
                            } else {
                                val curScalePx = cameraScale * density.density
                                val minScreenX = bounds.minX * curScalePx + cameraOffsetX
                                val maxScreenX = bounds.maxX * curScalePx + cameraOffsetX
                                val minScreenY = bounds.minY * curScalePx + cameraOffsetY
                                val maxScreenY = bounds.maxY * curScalePx + cameraOffsetY
                                val threshold = 240f
                                minScreenX > -threshold || maxScreenX < viewportWidthPx + threshold ||
                                    minScreenY > -threshold || maxScreenY < viewportHeightPx + threshold
                            }
                        }
                            .distinctUntilChanged()
                            .collect { approachingEdge ->
                                if (approachingEdge) {
                                    delay(220)
                                    launchAppendFeed(forceRetry = false)
                                }
                            }
                    }

                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .pointerInput(Unit) {
                                detectTransformGestures { centroid, pan, zoom, _ ->
                                    val prevScale = cameraScale
                                    val nextScale = (prevScale * zoom).coerceIn(0.24f, 3.20f)
                                    val ratio = if (prevScale > 0.0001f) nextScale / prevScale else 1f
                                    cameraOffsetX = centroid.x - (centroid.x - cameraOffsetX) * ratio + pan.x
                                    cameraOffsetY = centroid.y - (centroid.y - cameraOffsetY) * ratio + pan.y
                                    cameraScale = nextScale
                                }
                            }
                    ) {
                        val useLargeImages = cameraScale >= 1.55f
                        visibleCards.forEach { card ->
                            key(card.id) {
                                val sx = (card.frame.x.toFloat() * scalePx + cameraOffsetX).roundToInt()
                                val sy = (card.frame.y.toFloat() * scalePx + cameraOffsetY).roundToInt()
                                val wDp = (card.frame.width * cameraScale).coerceAtLeast(24.0).dp
                                val hDp = (card.frame.height * cameraScale).coerceAtLeast(24.0).dp
                                val inTray = card.pin.id in trayPinIds
                                val imported = card.pin.id in importedPinIds
                                val latestFastPick by rememberUpdatedState(fastPickMode)
                                val latestPin by rememberUpdatedState(card.pin)

                                Box(
                                    modifier = Modifier
                                        .offset { IntOffset(sx, sy) }
                                        .size(width = wDp, height = hDp)
                                        .clip(RoundedCornerShape(14.dp))
                                        .background(
                                            card.pin.dominantColorHex?.let { parseHexColor(it) }
                                                ?: MaterialTheme.colorScheme.surfaceContainer
                                        )
                                        .border(
                                            width = if (inTray) 2.5.dp else 0.5.dp,
                                            color = if (inTray) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                                            shape = RoundedCornerShape(14.dp)
                                        )
                                        .pointerInput(card.pin.id) {
                                            detectTapGestures(
                                                onTap = {
                                                    if (latestFastPick) toggleTray(latestPin)
                                                    else pinDetailStack = listOf(latestPin)
                                                },
                                                onLongPress = { toggleTray(latestPin) }
                                            )
                                        }
                                ) {
                                    AsyncImage(
                                        model = card.pin.bestDisplayUrl(large = useLargeImages),
                                        contentDescription = card.pin.displayTitle,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize()
                                    )
                                    if (inTray) {
                                        Surface(
                                            shape = CircleShape,
                                            color = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.align(Alignment.TopEnd).padding(6.dp)
                                        ) {
                                            Icon(
                                                Icons.Rounded.Check,
                                                contentDescription = "已在托盘",
                                                tint = MaterialTheme.colorScheme.onPrimary,
                                                modifier = Modifier.padding(4.dp).size(14.dp)
                                            )
                                        }
                                    }
                                    if (imported) {
                                        Surface(
                                            shape = CircleShape,
                                            color = Color.Black.copy(alpha = 0.64f),
                                            modifier = Modifier.align(Alignment.TopStart).padding(6.dp)
                                        ) {
                                            Text(
                                                text = "已入库",
                                                color = Color.White,
                                                style = MaterialTheme.typography.labelSmall,
                                                modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        if (isLoadingFeed && cards.isEmpty()) {
                            Surface(
                                shape = RoundedCornerShape(20.dp),
                                color = floatingSurface,
                                shadowElevation = 6.dp,
                                modifier = Modifier
                                    .align(Alignment.Center)
                                    .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(20.dp))
                            ) {
                                Column(
                                    modifier = Modifier.padding(20.dp),
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    LoadingIndicator()
                                    Text("正在铺展 Pinterest 无限灵感空间…", style = MaterialTheme.typography.bodyMedium)
                                }
                            }
                        } else if (errorMessage != null && cards.isEmpty()) {
                            Surface(
                                shape = RoundedCornerShape(20.dp),
                                color = floatingSurface,
                                shadowElevation = 6.dp,
                                modifier = Modifier
                                    .align(Alignment.Center)
                                    .padding(24.dp)
                                    .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(20.dp))
                            ) {
                                Column(
                                    modifier = Modifier.padding(20.dp),
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Text(errorMessage.orEmpty(), style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
                                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        OutlinedButton(onClick = { launchFreshFeed(source) }) { Text("重试") }
                                        Button(onClick = { showLoginWebView = true }) { Text("重新登录") }
                                    }
                                }
                            }
                        }
                    }

                    // Top Floating Chrome
                    Column(
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = floatingSurface,
                                shadowElevation = 4.dp,
                                modifier = Modifier
                                    .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                                    .clip(CircleShape)
                                    .clickable(onClick = onClose)
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                                ) {
                                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, null, modifier = Modifier.size(16.dp))
                                    Text("库内", style = MaterialTheme.typography.labelLarge)
                                }
                            }

                            Box(modifier = Modifier.weight(1f)) {
                                Surface(
                                    shape = CircleShape,
                                    color = floatingSurface,
                                    shadowElevation = 4.dp,
                                    modifier = Modifier
                                        .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                                        .clip(CircleShape)
                                        .clickable { showSourceMenu = true }
                                ) {
                                    Row(
                                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                                    ) {
                                        Icon(
                                            Icons.Rounded.AutoAwesome,
                                            null,
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Text(
                                            text = source.label,
                                            style = MaterialTheme.typography.labelLarge,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.weight(1f, fill = false)
                                        )
                                        Icon(Icons.Rounded.KeyboardArrowDown, null, modifier = Modifier.size(16.dp))
                                    }
                                }
                                DropdownMenu(expanded = showSourceMenu, onDismissRequest = { showSourceMenu = false }) {
                                    DropdownMenuItem(
                                        text = { Text("主页推荐灵感") },
                                        leadingIcon = { Icon(Icons.Rounded.AutoAwesome, null) },
                                        onClick = {
                                            showSourceMenu = false
                                            launchFreshFeed(PinterestSourceUi.Home)
                                        }
                                    )
                                    if (boards.isNotEmpty()) {
                                        HorizontalDivider()
                                        boards.forEach { b ->
                                            DropdownMenuItem(
                                                text = { Text("${b.name} (${b.pinCount})", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                                onClick = {
                                                    showSourceMenu = false
                                                    launchFreshFeed(PinterestSourceUi.Board(b))
                                                }
                                            )
                                        }
                                    }
                                    HorizontalDivider()
                                    DropdownMenuItem(
                                        text = { Text("批量导入收藏（按画板分目录）") },
                                        leadingIcon = { Icon(Icons.Rounded.FolderCopy, null) },
                                        onClick = {
                                            showSourceMenu = false
                                            showBoardImportSheet = true
                                        }
                                    )
                                }
                            }

                            Surface(
                                shape = CircleShape,
                                color = floatingSurface,
                                shadowElevation = 4.dp,
                                modifier = Modifier.border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                            ) {
                                Row {
                                    IconButton(
                                        onClick = { showSearchBar = !showSearchBar },
                                        modifier = Modifier.size(38.dp)
                                    ) {
                                        Icon(
                                            if (showSearchBar) Icons.Rounded.Close else Icons.Rounded.Search,
                                            contentDescription = "搜索 Pinterest",
                                            modifier = Modifier.size(18.dp)
                                        )
                                    }
                                    IconButton(
                                        onClick = { recenterCamera() },
                                        modifier = Modifier.size(38.dp)
                                    ) {
                                        Icon(Icons.Rounded.CenterFocusStrong, contentDescription = "回到中心", modifier = Modifier.size(18.dp))
                                    }
                                    Box {
                                        IconButton(onClick = { showAccountMenu = true }, modifier = Modifier.size(38.dp)) {
                                            Icon(Icons.Rounded.MoreVert, contentDescription = "账号菜单", modifier = Modifier.size(18.dp))
                                        }
                                        DropdownMenu(expanded = showAccountMenu, onDismissRequest = { showAccountMenu = false }) {
                                            account?.let { acc ->
                                                DropdownMenuItem(
                                                    text = { Text(acc.displayName, fontWeight = FontWeight.SemiBold) },
                                                    onClick = { showAccountMenu = false }
                                                )
                                            }
                                            DropdownMenuItem(
                                                text = { Text("刷新当前空间") },
                                                leadingIcon = { Icon(Icons.Rounded.Refresh, null) },
                                                onClick = {
                                                    showAccountMenu = false
                                                    launchFreshFeed(source)
                                                }
                                            )
                                            DropdownMenuItem(
                                                text = { Text("按画板批量导入") },
                                                leadingIcon = { Icon(Icons.Rounded.FolderCopy, null) },
                                                onClick = {
                                                    showAccountMenu = false
                                                    showBoardImportSheet = true
                                                }
                                            )
                                            HorizontalDivider()
                                            DropdownMenuItem(
                                                text = { Text("退出 Pinterest", color = MaterialTheme.colorScheme.error) },
                                                leadingIcon = { Icon(Icons.AutoMirrored.Rounded.Logout, null, tint = MaterialTheme.colorScheme.error) },
                                                onClick = {
                                                    showAccountMenu = false
                                                    feedJob?.cancel()
                                                    loadMoreJob?.cancel()
                                                    autoLoginCheckJob?.cancel()
                                                    feedSessionToken += 1
                                                    runCatching {
                                                        CookieManager.getInstance().removeAllCookies {
                                                            CookieManager.getInstance().flush()
                                                        }
                                                    }
                                                    lastLoginHostUrl = null
                                                    account = null
                                                    boards = emptyList()
                                                    pins = emptyList()
                                                    cards = emptyList()
                                                    trayPins = emptyList()
                                                    pinDetailStack = emptyList()
                                                    pinDetailCache.clear()
                                                    nextBookmark = null
                                                    hasMore = false
                                                    errorMessage = null
                                                    loadMoreError = null
                                                    isLoadingFeed = false
                                                    isLoadingMore = false
                                                    store.showToast("已退出 Pinterest 登录")
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        AnimatedVisibility(visible = showSearchBar) {
                            OutlinedTextField(
                                value = searchQuery,
                                onValueChange = { searchQuery = it },
                                placeholder = { Text("搜索 Pinterest 视觉灵感，如 editorial typography…") },
                                singleLine = true,
                                shape = CircleShape,
                                trailingIcon = {
                                    TextButton(
                                        onClick = {
                                            val q = searchQuery.trim()
                                            if (q.isNotEmpty()) {
                                                showSearchBar = false
                                                launchFreshFeed(PinterestSourceUi.Search(q))
                                            }
                                        }
                                    ) { Text("搜索") }
                                },
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                                keyboardActions = KeyboardActions(
                                    onSearch = {
                                        val q = searchQuery.trim()
                                        if (q.isNotEmpty()) {
                                            showSearchBar = false
                                            launchFreshFeed(PinterestSourceUi.Search(q))
                                        }
                                    }
                                ),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(
                                        if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLowest,
                                        CircleShape
                                    )
                            )
                        }
                    }

                    // Bottom Floating Mode Switcher, Pagination Error Pill & Shopping-Cart Tray
                    Column(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(horizontal = 14.dp, vertical = 14.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (loadMoreError != null && cards.isNotEmpty()) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.errorContainer,
                                contentColor = MaterialTheme.colorScheme.onErrorContainer,
                                shadowElevation = 4.dp
                            ) {
                                Row(
                                    modifier = Modifier.padding(start = 14.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    Text(
                                        text = loadMoreError.orEmpty(),
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f, fill = false)
                                    )
                                    TextButton(onClick = { launchAppendFeed(forceRetry = true) }) {
                                        Text("重试加载")
                                    }
                                    if (loadMoreError?.contains("登录") == true) {
                                        TextButton(onClick = { showLoginWebView = true }) {
                                            Text("重新登录")
                                        }
                                    }
                                }
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            CharkleConnectedButtonGroup(
                                height = 42.dp,
                                items = listOf(
                                    ConnectedActionItem(
                                        icon = Icons.Rounded.Explore,
                                        contentDescription = "探索模式",
                                        label = "探索",
                                        checked = !fastPickMode,
                                        onClick = { fastPickMode = false }
                                    ),
                                    ConnectedActionItem(
                                        icon = Icons.Rounded.TouchApp,
                                        contentDescription = "快选模式",
                                        label = "快选",
                                        checked = fastPickMode,
                                        onClick = { fastPickMode = true }
                                    )
                                )
                            )

                            if (isLoadingMore) {
                                LoadingIndicator(modifier = Modifier.size(28.dp))
                            }

                            Button(
                                onClick = { showTraySheet = true },
                                shape = CircleShape
                            ) {
                                Icon(Icons.Rounded.ShoppingBag, null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text(if (trayPins.isEmpty()) "托盘" else "托盘 · ${trayPins.size}")
                            }
                        }
                    }
                }
            }
        }
    }

    // Embedded WebView Login Dialog (User interacts directly; strict lifecycle cleanup)
    if (showLoginWebView) {
        var loginProgress by remember { mutableIntStateOf(0) }
        var webViewCanGoBack by remember { mutableStateOf(false) }
        var activeWebView by remember { mutableStateOf<WebView?>(null) }

        Dialog(
            onDismissRequest = {
                autoLoginCheckJob?.cancel()
                showLoginWebView = false
            },
            properties = DialogProperties(usePlatformDefaultWidth = false)
        ) {
            BackHandler(enabled = webViewCanGoBack) {
                activeWebView?.goBack()
            }
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Column(modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        TextButton(
                            onClick = {
                                autoLoginCheckJob?.cancel()
                                showLoginWebView = false
                            }
                        ) { Text("关闭") }
                        Text("登录 Pinterest", style = MaterialTheme.typography.titleMedium)
                        Button(
                            onClick = {
                                autoLoginCheckJob?.cancel()
                                showLoginWebView = false
                                scope.launch {
                                    verifySessionAndBootstrap()
                                    if (account != null) {
                                        store.showToast("已登录 Pinterest（${account?.displayName}）")
                                    } else {
                                        store.showToast("尚未检测到登录态，请先完成网页登录")
                                    }
                                }
                            },
                            shape = CircleShape
                        ) { Text("完成验证") }
                    }
                    if (loginProgress in 1..99) {
                        CharkleWavyProgress(
                            progress = loginProgress / 100f,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)
                        )
                    }
                    PinterestLoginWebView(
                        onWebViewCreated = { activeWebView = it },
                        onWebViewDisposed = { activeWebView = null },
                        onProgressChanged = { loginProgress = it },
                        onNavigationStateChanged = { url, canGoBack ->
                            webViewCanGoBack = canGoBack
                            if (!url.isNullOrBlank() && url.contains("pinterest.", ignoreCase = true)) {
                                lastLoginHostUrl = url
                            }
                        },
                        onPossiblySignedIn = { visitedUrl ->
                            if (!visitedUrl.isNullOrBlank()) {
                                lastLoginHostUrl = visitedUrl
                            }
                            if (autoLoginCheckJob?.isActive == true) return@PinterestLoginWebView
                            autoLoginCheckJob = scope.launch {
                                val acc = runCatching {
                                    store.repository.pinterestCheckSession(currentCookieHeader())
                                }.getOrNull()
                                if (acc != null && showLoginWebView) {
                                    showLoginWebView = false
                                    verifySessionAndBootstrap()
                                    store.showToast("已登录 Pinterest（${acc.displayName}）")
                                }
                            }
                        },
                        modifier = Modifier.weight(1f).fillMaxWidth()
                    )
                }
            }
        }
    }

    // Pin Detail + Multi-Level Similar Pin Drill-Down Bottom Sheet
    activeDetailPin?.let { pin ->
        val detailedPin = pinDetailResult?.pin ?: pin
        val similarPins = pinDetailResult?.similarPins.orEmpty()
        val inTray = trayPins.any { it.id == detailedPin.id }
        val alreadyImported = detailedPin.id in importedPinIds
        val detailScrollState = rememberScrollState()

        LaunchedEffect(pin.id) {
            detailScrollState.scrollTo(0)
        }

        ModalBottomSheet(
            onDismissRequest = { pinDetailStack = emptyList() },
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
        ) {
            BackHandler(enabled = pinDetailStack.size > 1) {
                pinDetailStack = pinDetailStack.dropLast(1)
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(detailScrollState)
                    .padding(horizontal = 16.dp)
                    .navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                // Header row with drill-down back navigation & close action
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    if (pinDetailStack.size > 1) {
                        FilledTonalButton(
                            onClick = { pinDetailStack = pinDetailStack.dropLast(1) },
                            shape = CircleShape
                        ) {
                            Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回上一个 Pin", modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("上一个 (${pinDetailStack.size - 1}/${pinDetailStack.size})")
                        }
                    } else {
                        Text(
                            text = detailedPin.boardName?.takeIf { it.isNotBlank() } ?: "灵感详情",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        if (alreadyImported) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.primaryContainer
                            ) {
                                Text(
                                    text = "已入库",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                                )
                            }
                        }
                        IconButton(
                            onClick = { pinDetailStack = emptyList() },
                            modifier = Modifier.size(34.dp)
                        ) {
                            Icon(Icons.Rounded.Close, contentDescription = "关闭详情", modifier = Modifier.size(18.dp))
                        }
                    }
                }

                AsyncImage(
                    model = detailedPin.bestDisplayUrl(large = true),
                    contentDescription = detailedPin.displayTitle,
                    contentScale = ContentScale.Fit,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(300.dp)
                        .clip(RoundedCornerShape(18.dp))
                        .background(MaterialTheme.colorScheme.surfaceContainer)
                )
                Text(detailedPin.displayTitle, style = MaterialTheme.typography.titleMedium)
                if (detailedPin.description.isNotBlank() && detailedPin.description != detailedPin.title) {
                    Text(
                        detailedPin.description,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                // Target folder selection for direct single-pin import
                if (state.folders.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            text = "直接入库目标目录",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            FilterChip(
                                selected = preferredImportFolderId == null,
                                onClick = { preferredImportFolderId = null },
                                label = { Text("收件箱") }
                            )
                            state.folders.forEach { folder ->
                                FilterChip(
                                    selected = preferredImportFolderId == folder.id,
                                    onClick = { preferredImportFolderId = folder.id },
                                    leadingIcon = {
                                        Icon(Icons.Rounded.Folder, contentDescription = null, modifier = Modifier.size(15.dp))
                                    },
                                    label = { Text(folder.name, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                                )
                            }
                        }
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    FilledTonalButton(
                        onClick = { toggleTray(detailedPin) },
                        shape = CircleShape,
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Rounded.ShoppingBag, null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(if (inTray) "移出托盘" else "加入托盘")
                    }
                    Button(
                        onClick = {
                            if (isImporting) return@Button
                            val targetFolder = preferredImportFolderId
                            val targetFolderName = state.folders.firstOrNull { it.id == targetFolder }?.name ?: "收件箱"
                            scope.launch {
                                isImporting = true
                                try {
                                    val report = store.repository.pinterestImportPins(
                                        pins = listOf(detailedPin),
                                        targetFolderId = targetFolder,
                                        skipDuplicates = true
                                    )
                                    refreshImportedPinIds()
                                    if (report.importedAssets.isNotEmpty()) {
                                        importedPinIds = importedPinIds + detailedPin.id
                                        trayPins = trayPins.filterNot { it.id == detailedPin.id }
                                        store.reloadLibrary(quiet = true)
                                        store.showToast("已直接入库原图至「$targetFolderName」")
                                    } else if (report.skippedDuplicatePinIds.isNotEmpty()) {
                                        importedPinIds = importedPinIds + detailedPin.id
                                        store.showToast("该灵感已在素材库中，已跳过重复")
                                    } else {
                                        store.showToast(report.errors.firstOrNull() ?: "原图下载或入库失败")
                                    }
                                } catch (err: Exception) {
                                    store.showToast("入库失败：${err.message ?: "请检查网络"}")
                                } finally {
                                    isImporting = false
                                }
                            }
                        },
                        enabled = !isImporting,
                        shape = CircleShape,
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Rounded.Download, null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(
                            when {
                                isImporting -> "入库中…"
                                alreadyImported -> "已在库内"
                                else -> "直接入库"
                            }
                        )
                    }
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(
                        onClick = {
                            pinDetailStack = emptyList()
                            launchFreshFeed(PinterestSourceUi.Similar(detailedPin))
                        },
                        shape = CircleShape,
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Rounded.Explore, null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(4.dp))
                        Text("在空间中探索相似")
                    }
                    if (detailedPin.pinPageUrl.isNotBlank()) {
                        OutlinedButton(
                            onClick = {
                                runCatching {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, detailedPin.pinPageUrl.toUri()))
                                }.onFailure {
                                    store.showToast("无法打开外部链接")
                                }
                            },
                            shape = CircleShape
                        ) {
                            Icon(Icons.AutoMirrored.Rounded.OpenInNew, null, modifier = Modifier.size(16.dp))
                        }
                    }
                }

                Text("相似视觉灵感（点击可逐层深入）", style = MaterialTheme.typography.titleSmall)
                when {
                    isLoadingDetail -> {
                        Box(Modifier.fillMaxWidth().padding(18.dp), contentAlignment = Alignment.Center) {
                            LoadingIndicator()
                        }
                    }
                    pinDetailError != null -> {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text(
                                text = pinDetailError.orEmpty(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.weight(1f)
                            )
                            TextButton(onClick = { detailRetryTick += 1 }) { Text("重试") }
                        }
                    }
                    similarPins.isEmpty() -> {
                        Text("暂无更多相似推荐", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    else -> {
                        LazyVerticalGrid(
                            columns = GridCells.Fixed(2),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.height(340.dp)
                        ) {
                            items(similarPins, key = { it.id }) { sim ->
                                val simImported = sim.id in importedPinIds
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .aspectRatio(0.8f)
                                        .clip(RoundedCornerShape(14.dp))
                                        .background(MaterialTheme.colorScheme.surfaceContainer)
                                        .clickable {
                                            if (pinDetailStack.lastOrNull()?.id != sim.id) {
                                                pinDetailStack = pinDetailStack + sim
                                            }
                                        }
                                ) {
                                    AsyncImage(
                                        model = sim.bestDisplayUrl(),
                                        contentDescription = sim.displayTitle,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize()
                                    )
                                    if (simImported) {
                                        Surface(
                                            shape = CircleShape,
                                            color = Color.Black.copy(alpha = 0.62f),
                                            modifier = Modifier.align(Alignment.TopStart).padding(6.dp)
                                        ) {
                                            Text(
                                                text = "已入库",
                                                color = Color.White,
                                                style = MaterialTheme.typography.labelSmall,
                                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Spacer(Modifier.height(16.dp))
            }
        }
    }

    // Shopping-Cart Tray Sheet
    if (showTraySheet) {
        ModalBottomSheet(
            onDismissRequest = { if (!isImporting) showTraySheet = false },
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("灵感暂存托盘 (${trayPins.size})", style = MaterialTheme.typography.titleLarge)
                    if (trayPins.isNotEmpty() && !isImporting) {
                        TextButton(onClick = { trayPins = emptyList() }) { Text("清空") }
                    }
                }

                if (trayPins.isEmpty()) {
                    Text(
                        "开启左下角「快选」或长按任意卡片即可加入托盘，支持一键原图去重批量导入 Charkle。",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 20.dp)
                    )
                } else {
                    if (state.folders.isNotEmpty()) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(
                                text = "目标目录",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                FilterChip(
                                    selected = preferredImportFolderId == null,
                                    onClick = { preferredImportFolderId = null },
                                    label = { Text("收件箱") }
                                )
                                state.folders.forEach { folder ->
                                    FilterChip(
                                        selected = preferredImportFolderId == folder.id,
                                        onClick = { preferredImportFolderId = folder.id },
                                        leadingIcon = {
                                            Icon(Icons.Rounded.Folder, contentDescription = null, modifier = Modifier.size(15.dp))
                                        },
                                        label = { Text(folder.name, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                                    )
                                }
                            }
                        }
                    }

                    if (isImporting) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            LoadingIndicator(modifier = Modifier.size(28.dp))
                            Text(
                                text = importProgressLabel ?: "正在下载原图并去重入库…",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }

                    LazyVerticalGrid(
                        columns = GridCells.Fixed(3),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.height(280.dp)
                    ) {
                        items(trayPins, key = { it.id }) { pin ->
                            Box(
                                modifier = Modifier
                                    .aspectRatio(0.85f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .clickable(enabled = !isImporting) {
                                        showTraySheet = false
                                        pinDetailStack = listOf(pin)
                                    }
                            ) {
                                AsyncImage(
                                    model = pin.bestDisplayUrl(),
                                    contentDescription = pin.displayTitle,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize()
                                )
                                if (!isImporting) {
                                    IconButton(
                                        onClick = { trayPins = trayPins.filterNot { it.id == pin.id } },
                                        modifier = Modifier
                                            .align(Alignment.TopEnd)
                                            .padding(4.dp)
                                            .size(24.dp)
                                            .background(Color.Black.copy(alpha = 0.6f), CircleShape)
                                    ) {
                                        Icon(Icons.Rounded.Close, "移出", tint = Color.White, modifier = Modifier.size(14.dp))
                                    }
                                }
                            }
                        }
                    }

                    Button(
                        onClick = {
                            if (isImporting) return@Button
                            val snapshot = trayPins
                            val targetFolder = preferredImportFolderId
                            scope.launch {
                                isImporting = true
                                importProgressLabel = "正在下载并入库 ${snapshot.size} 项原图…"
                                try {
                                    val report = store.repository.pinterestImportPins(
                                        pins = snapshot,
                                        targetFolderId = targetFolder,
                                        skipDuplicates = true
                                    )
                                    val failedSet = report.failedPinIds.toHashSet()
                                    val succeededOrDupIds = snapshot
                                        .map { it.id }
                                        .filterNot { it in failedSet }
                                        .toSet()
                                    refreshImportedPinIds()
                                    importedPinIds = importedPinIds + succeededOrDupIds + report.skippedDuplicatePinIds
                                    // Retain failed pins in tray so user can retry immediately
                                    trayPins = trayPins.filter { it.id in failedSet }
                                    store.reloadLibrary(quiet = true)
                                    if (failedSet.isEmpty()) {
                                        showTraySheet = false
                                    }
                                    val summary = buildString {
                                        append("导入完成：新增 ${report.importedAssets.size}，跳过重复 ${report.skippedDuplicatePinIds.size}")
                                        if (failedSet.isNotEmpty()) {
                                            append("，失败 ${failedSet.size}（已保留在托盘）")
                                        }
                                    }
                                    store.showToast(summary)
                                } catch (err: Exception) {
                                    store.showToast("批量导入失败：${err.message ?: "请稍后重试"}")
                                } finally {
                                    isImporting = false
                                    importProgressLabel = null
                                }
                            }
                        },
                        enabled = !isImporting,
                        shape = CircleShape,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(if (isImporting) "正在下载原图并入库…" else "一键批量导入 ${trayPins.size} 项原图")
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
        }
    }

    // Batch Import Saved Collections by Board Sheet
    if (showBoardImportSheet) {
        var selectedBoardIds by remember { mutableStateOf(emptySet<String>()) }
        var destMode by remember { mutableStateOf("pinterestRootFolder") }
        var existingParentFolderId by remember { mutableStateOf(state.folders.firstOrNull()?.id) }

        ModalBottomSheet(
            onDismissRequest = { if (!isImporting) showBoardImportSheet = false },
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
        ) {
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
                    Text("按画板批量导入收藏", style = MaterialTheme.typography.titleLarge)
                    if (boards.isNotEmpty() && !isImporting) {
                        val allSelected = selectedBoardIds.size == boards.size
                        TextButton(
                            onClick = {
                                selectedBoardIds = if (allSelected) emptySet() else boards.map { it.id }.toSet()
                            }
                        ) {
                            Text(if (allSelected) "取消全选" else "全选")
                        }
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    FilterChip(
                        selected = destMode == "pinterestRootFolder",
                        onClick = { destMode = "pinterestRootFolder" },
                        label = { Text("归入 Pinterest/ 子目录") }
                    )
                    FilterChip(
                        selected = destMode == "libraryRoot",
                        onClick = { destMode = "libraryRoot" },
                        label = { Text("直接建根目录文件夹") }
                    )
                    if (state.folders.isNotEmpty()) {
                        FilterChip(
                            selected = destMode == "existingFolder",
                            onClick = {
                                destMode = "existingFolder"
                                if (existingParentFolderId == null) {
                                    existingParentFolderId = state.folders.firstOrNull()?.id
                                }
                            },
                            label = { Text("指定已有文件夹") }
                        )
                    }
                }

                if (destMode == "existingFolder" && state.folders.isNotEmpty()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        state.folders.forEach { folder ->
                            FilterChip(
                                selected = existingParentFolderId == folder.id,
                                onClick = { existingParentFolderId = folder.id },
                                leadingIcon = {
                                    Icon(Icons.Rounded.Folder, contentDescription = null, modifier = Modifier.size(15.dp))
                                },
                                label = { Text(folder.name, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                            )
                        }
                    }
                }

                if (isImporting) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        LoadingIndicator(modifier = Modifier.size(28.dp))
                        Text(
                            text = importProgressLabel ?: "正在按画板拉取并导入原图…",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                if (boards.isEmpty()) {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = if (isRefreshingBoards) "正在刷新画板列表…" else "未获取到公开或个人画板列表，请确认 Pinterest 账号已设置用户名后刷新。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                        OutlinedButton(
                            onClick = { scope.launch { refreshUserBoards() } },
                            enabled = !isRefreshingBoards,
                            shape = CircleShape
                        ) {
                            Icon(Icons.Rounded.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(if (isRefreshingBoards) "刷新中…" else "刷新画板列表")
                        }
                    }
                } else {
                    LazyColumn(modifier = Modifier.height(290.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        items(boards, key = { it.id }) { board ->
                            val checked = board.id in selectedBoardIds
                            Surface(
                                shape = RoundedCornerShape(14.dp),
                                color = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainerLowest,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = !isImporting) {
                                        selectedBoardIds = if (checked) selectedBoardIds - board.id else selectedBoardIds + board.id
                                    }
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Checkbox(
                                        checked = checked,
                                        enabled = !isImporting,
                                        onCheckedChange = {
                                            selectedBoardIds = if (it) selectedBoardIds + board.id else selectedBoardIds - board.id
                                        }
                                    )
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            board.name,
                                            style = MaterialTheme.typography.titleSmall,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                        Text(
                                            "${board.pinCount} 个灵感",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                }
                            }
                        }
                    }

                    val canImport = selectedBoardIds.isNotEmpty() &&
                        !isImporting &&
                        (destMode != "existingFolder" || existingParentFolderId != null)

                    Button(
                        onClick = {
                            if (!canImport) return@Button
                            val chosen = boards.filter { it.id in selectedBoardIds }
                            val parentId = existingParentFolderId
                            val destJson = if (destMode == "existingFolder" && parentId != null) {
                                buildJsonObject {
                                    put("kind", "existingFolder")
                                    put("folderID", parentId.uppercase())
                                }.toString()
                            } else {
                                buildJsonObject { put("kind", destMode) }.toString()
                            }
                            scope.launch {
                                isImporting = true
                                importProgressLabel = "正在分画板导入 ${chosen.size} 个画板…"
                                try {
                                    val report = store.repository.pinterestImportBoards(
                                        cookieHeader = currentCookieHeader(),
                                        boards = chosen,
                                        destinationJson = destJson,
                                        skipDuplicates = true
                                    )
                                    refreshImportedPinIds()
                                    store.reloadLibrary(quiet = true)
                                    showBoardImportSheet = false
                                    val summary = buildString {
                                        append("画板导入完成：新增 ${report.importedAssetCount}，跳过重复 ${report.skippedDuplicateCount}")
                                        if (report.failedPinCount > 0) {
                                            append("，失败 ${report.failedPinCount}")
                                        }
                                    }
                                    store.showToast(summary)
                                } catch (err: Exception) {
                                    store.showToast("画板导入失败：${err.message ?: "请检查网络或重新登录"}")
                                } finally {
                                    isImporting = false
                                    importProgressLabel = null
                                }
                            }
                        },
                        enabled = canImport,
                        shape = CircleShape,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(if (isImporting) "正在分画板批量导入…" else "导入所选 ${selectedBoardIds.size} 个画板")
                    }
                }
                Spacer(Modifier.height(12.dp))
            }
        }
    }
}

@Composable
private fun WelcomeFeatureBadge(
    icon: ImageVector,
    label: String,
    modifier: Modifier = Modifier
) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = MaterialTheme.colorScheme.onSurface,
        modifier = modifier.height(38.dp)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally)
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
            Text(label, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun PinterestLoginWebView(
    onWebViewCreated: (WebView) -> Unit,
    onWebViewDisposed: () -> Unit,
    onProgressChanged: (Int) -> Unit,
    onNavigationStateChanged: (String?, Boolean) -> Unit,
    onPossiblySignedIn: (String?) -> Unit,
    modifier: Modifier = Modifier
) {
    val latestOnCreated by rememberUpdatedState(onWebViewCreated)
    val latestOnDisposed by rememberUpdatedState(onWebViewDisposed)
    val latestOnProgress by rememberUpdatedState(onProgressChanged)
    val latestOnNavChanged by rememberUpdatedState(onNavigationStateChanged)
    val latestOnPossiblySignedIn by rememberUpdatedState(onPossiblySignedIn)

    var webViewInstance by remember { mutableStateOf<WebView?>(null) }
    var isDestroyed by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        onDispose {
            val view = webViewInstance
            if (view != null && !isDestroyed) {
                isDestroyed = true
                tearDownWebViewSafely(view)
                webViewInstance = null
                latestOnDisposed()
            }
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            WebView(ctx).apply {
                val cm = CookieManager.getInstance()
                cm.setAcceptCookie(true)
                cm.setAcceptThirdPartyCookies(this, true)
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.userAgentString =
                    "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
                webChromeClient = object : WebChromeClient() {
                    override fun onProgressChanged(view: WebView?, newProgress: Int) {
                        super.onProgressChanged(view, newProgress)
                        latestOnProgress(newProgress)
                    }
                }
                webViewClient = object : WebViewClient() {
                    override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
                        super.doUpdateVisitedHistory(view, url, isReload)
                        latestOnNavChanged(url, view?.canGoBack() == true)
                    }

                    override fun onPageFinished(view: WebView?, url: String?) {
                        super.onPageFinished(view, url)
                        runCatching { CookieManager.getInstance().flush() }
                        latestOnNavChanged(url, view?.canGoBack() == true)
                        val u = url.orEmpty().lowercase()
                        if (u.contains("pinterest.") &&
                            !u.contains("/login") &&
                            !u.contains("/oauth") &&
                            !u.contains("/connect")
                        ) {
                            latestOnPossiblySignedIn(url)
                        }
                    }
                }
                webViewInstance = this
                latestOnCreated(this)
                loadUrl("https://www.pinterest.com/login/")
            }
        },
        onRelease = { view ->
            if (!isDestroyed) {
                isDestroyed = true
                tearDownWebViewSafely(view)
                webViewInstance = null
                latestOnDisposed()
            }
        }
    )
}

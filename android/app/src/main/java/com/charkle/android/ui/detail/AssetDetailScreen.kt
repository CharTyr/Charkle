@file:OptIn(ExperimentalMaterial3ExpressiveApi::class, ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package com.charkle.android.ui.detail

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateCentroidSize
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.DriveFileMove
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.rounded.RotateRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ColorLens
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Flip
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.RestoreFromTrash
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import com.charkle.android.core.AssetDto
import com.charkle.android.core.ScoredAssetDto
import com.charkle.android.designsystem.ArtworkDynamicExpressiveTheme
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.CharkleExpressiveLoader
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.ExpressiveHeroTransportRow
import com.charkle.android.designsystem.ExpressivePillToggleChip
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.LocalCharkleReduceMotion
import com.charkle.android.designsystem.SegmentedRowCard
import com.charkle.android.designsystem.SegmentedSection
import com.charkle.android.designsystem.expressiveZoneBBackdropBrush
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.designsystem.rememberAssetPreviewFile
import com.charkle.android.designsystem.rememberAssetThumbnailFile
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Zone B: Artwork-driven Material 3 Expressive full-screen Quick Look.
 * Features faithful artwork color harmonization (`PaletteStyle.Fidelity`), 1-tap Neutral Color-Proofing,
 * rich media viewers (Image / Media3 Video / Wavy Audio / PDF / Social / GitHub / Markdown),
 * synchronized bottom Filmstrip scrubber, native FileProvider Share, and full editable Inspector.
 * Preserves confirmed UX invariants: no linear/bar progress below Quick Look, zero cropping on 90° rotation.
 */
@Composable
fun AssetDetailScreen(
    assets: List<AssetDto>,
    initialAssetId: String,
    state: CharkleUiState,
    store: CharkleAppStore,
    onDismiss: () -> Unit,
    onFilterByColor: (String) -> Unit,
    inspectorTab: Int = 0,
    onSelectInspectorTab: ((Int) -> Unit)? = null,
    onOpenExternalAsset: ((AssetDto) -> Unit)? = null
) {
    BackHandler(onBack = onDismiss)
    val context = LocalContext.current
    val density = LocalDensity.current
    val reduceMotion = LocalCharkleReduceMotion.current

    LaunchedEffect(assets.isEmpty()) {
        if (assets.isEmpty()) {
            onDismiss()
        }
    }
    if (assets.isEmpty()) return

    val initialIndex = remember(initialAssetId) {
        assets.indexOfFirst { it.id == initialAssetId }.coerceAtLeast(0)
    }
    val pagerState = rememberPagerState(initialPage = initialIndex) { assets.size }
    val filmstripState = rememberLazyListState(initialFirstVisibleItemIndex = initialIndex)
    val coroutineScope = rememberCoroutineScope()

    val safePage = pagerState.currentPage.coerceIn(0, assets.lastIndex)
    val currentAsset = assets[safePage]
    val isDark = LocalCharkleExtendedColors.current.isDark

    var isChromeVisible by remember { mutableStateOf(true) }
    var colorProofing by remember { mutableStateOf(state.defaultColorProofing) }
    var showInspectorSheet by remember { mutableStateOf(false) }
    var localInspectorTab by remember { mutableIntStateOf(inspectorTab) }
    val activeInspectorTab = if (onSelectInspectorTab != null) inspectorTab else localInspectorTab
    val setInspectorTab: (Int) -> Unit = { tab ->
        localInspectorTab = tab
        onSelectInspectorTab?.invoke(tab)
    }
    var showFolderSheet by remember { mutableStateOf(false) }
    var rotationDeg by remember(currentAsset.id) { mutableFloatStateOf(0f) }
    var flipX by remember(currentAsset.id) { mutableStateOf(false) }

    val activeThumbHalfPx = with(density) { 26.dp.roundToPx() }

    LaunchedEffect(currentAsset.id, safePage) {
        store.markOpened(currentAsset.id)
        store.selectInspectedAsset(currentAsset.id)
        if (assets.size > 1) {
            val viewportWidth = filmstripState.layoutInfo.viewportSize.width
            val centerOffset = if (viewportWidth > 0) -(viewportWidth / 2 - activeThumbHalfPx) else 0
            val dist = abs(filmstripState.firstVisibleItemIndex - safePage)
            if (dist > 15 || reduceMotion) {
                filmstripState.scrollToItem(safePage, centerOffset)
            } else {
                filmstripState.animateScrollToItem(safePage, centerOffset)
            }
        }
    }

    val currentIsPdf = currentAsset.fileName.endsWith(".pdf", ignoreCase = true) ||
        currentAsset.mimeType.equals("application/pdf", ignoreCase = true)
    val currentIsRichEditorial = currentAsset.richMetadata?.githubRepo != null ||
        currentAsset.richMetadata?.socialPost != null ||
        currentAsset.richMetadata?.isMarkdown == true ||
        (currentAsset.mediaKind == "webBookmark" && !currentAsset.sourceUrl.isNullOrBlank())
    val currentSupportsImageTransform = currentAsset.mediaKind != "video" &&
        currentAsset.mediaKind != "audio" &&
        !currentIsPdf &&
        !currentIsRichEditorial

    val dominantHexes = remember(currentAsset.id, currentAsset.dominantColors) {
        currentAsset.dominantColors.map { it.hex }
    }

    ArtworkDynamicExpressiveTheme(
        dominantHexes = dominantHexes,
        isDark = isDark,
        colorProofingEnabled = colorProofing
    ) {
        val backdropBrush = expressiveZoneBBackdropBrush(
            isDark = isDark,
            colorProofingEnabled = colorProofing
        )
        val chromeEnter = if (reduceMotion) {
            fadeIn(snap()) + expandVertically(snap())
        } else {
            fadeIn(MaterialTheme.motionScheme.fastEffectsSpec()) +
                expandVertically(MaterialTheme.motionScheme.defaultSpatialSpec())
        }
        val chromeExit = if (reduceMotion) {
            fadeOut(snap()) + shrinkVertically(snap())
        } else {
            fadeOut(MaterialTheme.motionScheme.fastEffectsSpec()) +
                shrinkVertically(MaterialTheme.motionScheme.defaultSpatialSpec())
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(backdropBrush)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding()
            ) {
                // Floating Expressive Top Chrome
                AnimatedVisibility(
                    visible = isChromeVisible,
                    enter = chromeEnter,
                    exit = chromeExit
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Surface(
                            onClick = onDismiss,
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primaryContainer,
                            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            modifier = Modifier.size(44.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                    contentDescription = "返回画廊"
                                )
                            }
                        }

                        Spacer(Modifier.width(12.dp))

                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = currentAsset.title,
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = "${currentAsset.displayTypeLabel} · ${currentAsset.pixelWidth} × ${currentAsset.pixelHeight}",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }

                        Spacer(Modifier.width(8.dp))

                        CharkleConnectedButtonGroup(
                            height = 44.dp,
                            containerColor = MaterialTheme.colorScheme.primaryContainer,
                            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                            items = listOf(
                                ConnectedActionItem(
                                    icon = if (currentAsset.rating > 0) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                                    contentDescription = "标星",
                                    checked = currentAsset.rating > 0,
                                    organicActiveShape = true,
                                    onClick = {
                                        store.setAssetRating(
                                            currentAsset.id,
                                            if (currentAsset.rating > 0) 0 else 5
                                        )
                                    }
                                ),
                                ConnectedActionItem(
                                    icon = Icons.Rounded.ColorLens,
                                    contentDescription = if (colorProofing) "恢复作品氛围色" else "原色校对模式",
                                    checked = colorProofing,
                                    onClick = { colorProofing = !colorProofing }
                                ),
                                ConnectedActionItem(
                                    icon = Icons.Rounded.Share,
                                    contentDescription = "分享素材",
                                    onClick = {
                                        coroutineScope.launch {
                                            val file = store.resolveOriginalFile(currentAsset.id)
                                            if (file != null) {
                                                val ok = shareLocalFile(
                                                    context = context,
                                                    file = file,
                                                    mimeType = currentAsset.mimeType,
                                                    title = currentAsset.title
                                                )
                                                if (!ok) {
                                                    store.showToast("无法分享该文件，请稍后重试")
                                                }
                                            } else {
                                                store.showToast("原图尚未下载到本地")
                                            }
                                        }
                                    }
                                )
                            )
                        )
                    }
                }

                // Unobstructed Multi-Format Media Stage
                HorizontalPager(
                    state = pagerState,
                    key = { page -> assets.getOrNull(page)?.id ?: page },
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                ) { page ->
                    val pageAsset = assets.getOrNull(page) ?: return@HorizontalPager
                    val isActivePage = page == safePage
                    val file = rememberAssetPreviewFile(
                        store = store,
                        assetId = pageAsset.id,
                        updatedAt = pageAsset.updatedAt,
                        upgradeToOriginal = true
                    )

                    val isPdf = pageAsset.fileName.endsWith(".pdf", ignoreCase = true) ||
                        pageAsset.mimeType.equals("application/pdf", ignoreCase = true)
                    val isRichEditorial = pageAsset.richMetadata?.githubRepo != null ||
                        pageAsset.richMetadata?.socialPost != null ||
                        pageAsset.richMetadata?.isMarkdown == true ||
                        (pageAsset.mediaKind == "webBookmark" && !pageAsset.sourceUrl.isNullOrBlank())

                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = if (isChromeVisible) 14.dp else 0.dp, vertical = 4.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        when {
                            pageAsset.mediaKind == "video" && file != null -> {
                                VideoPlayerStage(file = file, isActivePage = isActivePage)
                            }
                            pageAsset.mediaKind == "audio" && file != null -> {
                                AudioWavyPlayerStage(
                                    asset = pageAsset,
                                    file = file,
                                    isActivePage = isActivePage
                                )
                            }
                            isPdf && file != null -> {
                                PdfDocumentStage(file = file)
                            }
                            isRichEditorial -> {
                                RichEditorialCardStage(
                                    asset = pageAsset,
                                    coverFile = file,
                                    onOpenSourceUrl = { url -> openUrlInCustomTab(context, url) }
                                )
                            }
                            else -> {
                                ZoomableArtworkStage(
                                    asset = pageAsset,
                                    file = file,
                                    isActivePage = isActivePage,
                                    isChromeVisible = isChromeVisible,
                                    rotationDeg = if (isActivePage) rotationDeg else 0f,
                                    flipX = if (isActivePage) flipX else false,
                                    onToggleChrome = { isChromeVisible = !isChromeVisible }
                                )
                            }
                        }
                    }
                }

                // Bottom Filmstrip Scrubber + Palette + Expressive Transport Cluster
                // (Confirmed UX invariant: no linear/wavy bar progress indicator below Quick Look.)
                AnimatedVisibility(
                    visible = isChromeVisible,
                    enter = chromeEnter,
                    exit = chromeExit
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        // Synchronized Filmstrip Scrubber (when > 1 item)
                        if (assets.size > 1) {
                            LazyRow(
                                state = filmstripState,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                contentPadding = PaddingValues(horizontal = 2.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                itemsIndexed(assets, key = { _, a -> a.id }) { idx, item ->
                                    FilmstripThumbTile(
                                        asset = item,
                                        store = store,
                                        isCurrent = idx == safePage,
                                        reduceMotion = reduceMotion,
                                        onClick = {
                                            coroutineScope.launch {
                                                if (abs(idx - safePage) > 12 || reduceMotion) {
                                                    pagerState.scrollToPage(idx)
                                                } else {
                                                    pagerState.animateScrollToPage(idx)
                                                }
                                            }
                                        }
                                    )
                                }
                            }
                        }

                        // Tactile Expressive Pill Strip (Palette HEX + Quick Transform/Organize Pills)
                        LazyRow(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            currentAsset.dominantColors.take(2).forEach { swatch ->
                                val c = parseHexColor(swatch.hex) ?: return@forEach
                                item(key = "swatch_${swatch.hex}") {
                                    ExpressivePillToggleChip(
                                        label = swatch.hex.uppercase(Locale.ROOT),
                                        selected = false,
                                        swatchColor = c,
                                        unselectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        unselectedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                        onClick = {
                                            onDismiss()
                                            onFilterByColor(swatch.hex)
                                        }
                                    )
                                }
                            }
                            if (currentSupportsImageTransform) {
                                item(key = "act_rotate") {
                                    ExpressivePillToggleChip(
                                        label = "旋转",
                                        selected = (rotationDeg.roundToInt() % 360) != 0,
                                        leadingIcon = Icons.AutoMirrored.Rounded.RotateRight,
                                        unselectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        unselectedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                        onClick = { rotationDeg += 90f }
                                    )
                                }
                                item(key = "act_flip") {
                                    ExpressivePillToggleChip(
                                        label = "镜像",
                                        selected = flipX,
                                        leadingIcon = Icons.Rounded.Flip,
                                        unselectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        unselectedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                        onClick = { flipX = !flipX }
                                    )
                                }
                            }
                            if (!currentAsset.isTrashed) {
                                item(key = "act_move") {
                                    ExpressivePillToggleChip(
                                        label = "归类",
                                        selected = false,
                                        leadingIcon = Icons.AutoMirrored.Rounded.DriveFileMove,
                                        unselectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        unselectedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                        onClick = { showFolderSheet = true }
                                    )
                                }
                            }
                            item(key = "act_pin") {
                                ExpressivePillToggleChip(
                                    label = if (currentAsset.pinnedOffline) "已置顶" else "离线",
                                    selected = currentAsset.pinnedOffline,
                                    leadingIcon = Icons.Rounded.PushPin,
                                    unselectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                    unselectedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                    onClick = { store.toggleOfflinePin(currentAsset) }
                                )
                            }
                            item(key = "act_trash_or_restore") {
                                if (currentAsset.isTrashed) {
                                    ExpressivePillToggleChip(
                                        label = "恢复",
                                        selected = false,
                                        leadingIcon = Icons.Rounded.RestoreFromTrash,
                                        unselectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        unselectedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                        onClick = {
                                            store.restoreAssets(listOf(currentAsset.id))
                                            if (assets.size <= 1) onDismiss()
                                        }
                                    )
                                } else {
                                    ExpressivePillToggleChip(
                                        label = "回收",
                                        selected = false,
                                        leadingIcon = Icons.Rounded.DeleteOutline,
                                        unselectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                                        unselectedContentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                                        onClick = {
                                            store.trashAssets(listOf(currentAsset.id))
                                            if (assets.size <= 1) onDismiss()
                                        }
                                    )
                                }
                            }
                        }

                        // Signature M3 Expressive Hero Transport Row (Pill flanks + Squircle Hero Block + Ring Progress)
                        val deckProgress = (safePage + 1f) / assets.size.coerceAtLeast(1).toFloat()
                        ExpressiveHeroTransportRow(
                            leadingIcon = Icons.AutoMirrored.Rounded.KeyboardArrowLeft,
                            leadingDescription = "上一张",
                            leadingEnabled = safePage > 0,
                            onLeadingClick = {
                                if (safePage > 0) {
                                    coroutineScope.launch {
                                        pagerState.animateScrollToPage(safePage - 1)
                                    }
                                }
                            },
                            centerIcon = Icons.Rounded.Info,
                            centerLabel = "检查器 · ${safePage + 1}/${assets.size}",
                            onCenterClick = { showInspectorSheet = true },
                            trailingIcon = Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                            trailingDescription = "下一张",
                            trailingEnabled = safePage < assets.lastIndex,
                            trailingProgress = deckProgress,
                            onTrailingClick = {
                                if (safePage < assets.lastIndex) {
                                    coroutineScope.launch {
                                        pagerState.animateScrollToPage(safePage + 1)
                                    }
                                }
                            }
                        )
                    }
                }
            }

            if (showInspectorSheet) {
                ModalBottomSheet(
                    onDismissRequest = { showInspectorSheet = false },
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ) {
                    AssetInspectorPanel(
                        asset = currentAsset,
                        activeTab = activeInspectorTab,
                        onSelectTab = setInspectorTab,
                        store = store,
                        onFilterByColor = { hex ->
                            showInspectorSheet = false
                            onDismiss()
                            onFilterByColor(hex)
                        },
                        onSelectSimilar = { targetAsset ->
                            val idx = assets.indexOfFirst { it.id == targetAsset.id }
                            showInspectorSheet = false
                            if (idx >= 0) {
                                coroutineScope.launch { pagerState.animateScrollToPage(idx) }
                            } else {
                                onOpenExternalAsset?.invoke(targetAsset)
                            }
                        }
                    )
                }
            }

            if (showFolderSheet) {
                ModalBottomSheet(
                    onDismissRequest = { showFolderSheet = false },
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .verticalScroll(rememberScrollState())
                            .navigationBarsPadding()
                            .padding(horizontal = 20.dp)
                            .padding(bottom = 28.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Text("移动到文件夹", style = MaterialTheme.typography.titleMedium)
                        val rows = listOf<Pair<String?, String>>(null to "收件箱") +
                            state.folders.map { it.id to it.name }
                        SegmentedSection {
                            rows.forEachIndexed { idx, (fid, name) ->
                                SegmentedRowCard(
                                    index = idx,
                                    count = rows.size,
                                    onClick = {
                                        store.moveAssetsToFolder(listOf(currentAsset.id), fid, name)
                                        showFolderSheet = false
                                    }
                                ) {
                                    Text(
                                        name,
                                        style = MaterialTheme.typography.bodyMedium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    val isCurrentFolder = (currentAsset.folderId == null && fid == null) ||
                                        (currentAsset.folderId != null && fid != null &&
                                            currentAsset.folderId.equals(fid, ignoreCase = true))
                                    if (isCurrentFolder) {
                                        Text(
                                            "当前",
                                            style = MaterialTheme.typography.labelMedium,
                                            color = MaterialTheme.colorScheme.primary
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
}

@Composable
private fun FilmstripThumbTile(
    asset: AssetDto,
    store: CharkleAppStore,
    isCurrent: Boolean,
    reduceMotion: Boolean,
    onClick: () -> Unit
) {
    val context = LocalContext.current
    val widthDp by animateDpAsState(
        targetValue = if (isCurrent) 52.dp else 34.dp,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "filmstripWidth"
    )
    val thumb = rememberAssetThumbnailFile(
        store = store,
        assetId = asset.id,
        updatedAt = asset.updatedAt,
        previewTier = false
    )
    val request = remember(thumb, asset.id, asset.updatedAt, context) {
        thumb?.let {
            ImageRequest.Builder(context)
                .data(it)
                .memoryCacheKey("filmstrip_thumb:${asset.id}:${asset.updatedAt}")
                .build()
        }
    }
    val shape = if (isCurrent) RoundedCornerShape(12.dp) else RoundedCornerShape(8.dp)

    Box(
        modifier = Modifier
            .width(widthDp)
            .height(44.dp)
            .clip(shape)
            .background(MaterialTheme.colorScheme.primaryContainer)
            .then(
                if (isCurrent) {
                    Modifier.border(2.dp, MaterialTheme.colorScheme.primary, shape)
                } else {
                    Modifier
                }
            )
            .clickable(onClick = onClick)
    ) {
        if (request != null) {
            AsyncImage(
                model = request,
                contentDescription = asset.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}

/**
 * Interactive artwork viewport with:
 * - Pinch-to-zoom from 1.0x..8.0x anchored at pinch centroid (zero gesture cancellation mid-pinch)
 * - Bounded 1-finger pan matching screen coordinates at every rotation/mirror angle
 * - Seamless horizontal-edge handoff to [HorizontalPager] when reaching pan limits
 * - Double-tap animated zoom to tapped focal point or animated reset to 1.0x
 * - Uncropped 90°/270° rotation with true screen-space horizontal mirroring
 */
@Composable
private fun ZoomableArtworkStage(
    asset: AssetDto,
    file: File?,
    isActivePage: Boolean,
    isChromeVisible: Boolean,
    rotationDeg: Float,
    flipX: Boolean,
    onToggleChrome: () -> Unit
) {
    val reduceMotion = LocalCharkleReduceMotion.current
    val coroutineScope = rememberCoroutineScope()
    val spatialSpec = MaterialTheme.motionScheme.defaultSpatialSpec<Float>()

    var scale by remember(asset.id) { mutableFloatStateOf(1f) }
    var offsetX by remember(asset.id) { mutableFloatStateOf(0f) }
    var offsetY by remember(asset.id) { mutableFloatStateOf(0f) }
    var zoomAnimJob by remember(asset.id) { mutableStateOf<Job?>(null) }

    val animRotation by animateFloatAsState(
        targetValue = rotationDeg,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.defaultSpatialSpec(),
        label = "artworkRotation"
    )
    val animFlipX by animateFloatAsState(
        targetValue = if (flipX) -1f else 1f,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "artworkFlipX"
    )

    // Reset zoom/pan cleanly when user swipes away to another page.
    LaunchedEffect(isActivePage) {
        if (!isActivePage) {
            zoomAnimJob?.cancel()
            scale = 1f
            offsetX = 0f
            offsetY = 0f
        }
    }

    val naturalAspectRatio = if (asset.pixelWidth > 0 && asset.pixelHeight > 0) {
        asset.pixelWidth.toFloat() / asset.pixelHeight.toFloat()
    } else {
        asset.aspectRatio
    }.coerceAtLeast(0.1f)

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .clipToBounds(),
        contentAlignment = Alignment.Center
    ) {
        val density = LocalDensity.current
        val availW = maxWidth.value.coerceAtLeast(1f)
        val availH = maxHeight.value.coerceAtLeast(1f)
        val availWPx = with(density) { maxWidth.toPx() }.coerceAtLeast(1f)
        val availHPx = with(density) { maxHeight.toPx() }.coerceAtLeast(1f)
        val isQuarterTurn = (((rotationDeg.roundToInt() % 180) + 180) % 180) == 90

        val targetHeightDp = if (isQuarterTurn) {
            minOf(availW, availH / naturalAspectRatio)
        } else {
            minOf(availH, availW / naturalAspectRatio)
        }
        val targetWidthDp = targetHeightDp * naturalAspectRatio

        val targetWidthPx = with(density) { targetWidthDp.dp.toPx() }
        val targetHeightPx = with(density) { targetHeightDp.dp.toPx() }

        fun computeMaxOffsetX(forScale: Float): Float {
            val visualW = (if (isQuarterTurn) targetHeightPx else targetWidthPx) * forScale
            return ((visualW - availWPx) / 2f).coerceAtLeast(0f)
        }

        fun computeMaxOffsetY(forScale: Float): Float {
            val visualH = (if (isQuarterTurn) targetWidthPx else targetHeightPx) * forScale
            return ((visualH - availHPx) / 2f).coerceAtLeast(0f)
        }

        // Re-clamp translation when rotating or resizing viewport so artwork never drifts off bounds.
        LaunchedEffect(isQuarterTurn, availWPx, availHPx) {
            if (scale <= 1.02f) {
                offsetX = 0f
                offsetY = 0f
            } else {
                val maxX = computeMaxOffsetX(scale)
                val maxY = computeMaxOffsetY(scale)
                offsetX = offsetX.coerceIn(-maxX, maxX)
                offsetY = offsetY.coerceIn(-maxY, maxY)
            }
        }

        val latestComputeMaxX by rememberUpdatedState(::computeMaxOffsetX)
        val latestComputeMaxY by rememberUpdatedState(::computeMaxOffsetY)
        val latestToggleChrome by rememberUpdatedState(onToggleChrome)

        fun animateTransformTo(targetScale: Float, targetX: Float, targetY: Float) {
            zoomAnimJob?.cancel()
            if (reduceMotion) {
                scale = targetScale
                offsetX = targetX
                offsetY = targetY
                return
            }
            val startScale = scale
            val startX = offsetX
            val startY = offsetY
            zoomAnimJob = coroutineScope.launch {
                animate(
                    initialValue = 0f,
                    targetValue = 1f,
                    animationSpec = spatialSpec
                ) { t, _ ->
                    scale = startScale + (targetScale - startScale) * t
                    offsetX = startX + (targetX - startX) * t
                    offsetY = startY + (targetY - startY) * t
                }
                scale = targetScale
                offsetX = targetX
                offsetY = targetY
            }
        }

        val animatedWidth by animateDpAsState(
            targetValue = targetWidthDp.dp,
            animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.defaultSpatialSpec(),
            label = "rotatedArtworkWidth"
        )
        val animatedHeight by animateDpAsState(
            targetValue = targetHeightDp.dp,
            animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.defaultSpatialSpec(),
            label = "rotatedArtworkHeight"
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(asset.id) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        zoomAnimJob?.cancel()
                        var pastTouchSlop = false
                        var multiTouchActive = false
                        var panAccum = Offset.Zero
                        var zoomAccum = 1f
                        val touchSlop = viewConfiguration.touchSlop

                        do {
                            val event = awaitPointerEvent()
                            val canceled = event.changes.any { it.isConsumed }
                            if (!canceled) {
                                val pressedCount = event.changes.count { it.pressed }
                                val zoomChange = event.calculateZoom()
                                val panChange = event.calculatePan()

                                if (pressedCount >= 2) {
                                    multiTouchActive = true
                                }

                                if (!pastTouchSlop) {
                                    zoomAccum *= zoomChange
                                    panAccum += panChange
                                    val centroidSize = event.calculateCentroidSize(useCurrent = false)
                                    val zoomMotion = abs(1f - zoomAccum) * centroidSize
                                    val panMotion = panAccum.getDistance()

                                    if (zoomMotion > touchSlop || (pressedCount >= 2 && abs(1f - zoomAccum) > 0.02f)) {
                                        pastTouchSlop = true
                                    } else if (panMotion > touchSlop && scale > 1.02f) {
                                        val maxX = latestComputeMaxX(scale)
                                        val horizontalDominant = abs(panAccum.x) > abs(panAccum.y)
                                        val atLeftEdge = offsetX >= maxX - 2f && panAccum.x > 0f
                                        val atRightEdge = offsetX <= -maxX + 2f && panAccum.x < 0f
                                        // Allow HorizontalPager to take over when user drags further past the zoomed edge.
                                        if (!(horizontalDominant && (atLeftEdge || atRightEdge || maxX <= 1f))) {
                                            pastTouchSlop = true
                                        }
                                    }
                                }

                                if (pastTouchSlop && (multiTouchActive || scale > 1.02f)) {
                                    val oldScale = scale
                                    val newScale = (oldScale * zoomChange).coerceIn(1f, 8f)
                                    val newMaxX = latestComputeMaxX(newScale)
                                    val newMaxY = latestComputeMaxY(newScale)

                                    val centroid = event.calculateCentroid(useCurrent = false)
                                    val centerX = size.width / 2f
                                    val centerY = size.height / 2f
                                    val ratio = if (oldScale > 0f) newScale / oldScale else 1f

                                    val rawX = if (centroid != Offset.Unspecified && zoomChange != 1f) {
                                        (offsetX - (centroid.x - centerX)) * ratio + (centroid.x - centerX) + panChange.x
                                    } else {
                                        offsetX + panChange.x
                                    }
                                    val rawY = if (centroid != Offset.Unspecified && zoomChange != 1f) {
                                        (offsetY - (centroid.y - centerY)) * ratio + (centroid.y - centerY) + panChange.y
                                    } else {
                                        offsetY + panChange.y
                                    }

                                    val prevX = offsetX
                                    val prevY = offsetY
                                    val nextX = if (newScale <= 1.02f) 0f else rawX.coerceIn(-newMaxX, newMaxX)
                                    val nextY = if (newScale <= 1.02f) 0f else rawY.coerceIn(-newMaxY, newMaxY)

                                    scale = newScale
                                    offsetX = nextX
                                    offsetY = nextY

                                    val movedX = abs(nextX - prevX) > 0.25f
                                    val movedY = abs(nextY - prevY) > 0.25f
                                    val shouldConsume = pressedCount >= 2 ||
                                        zoomChange != 1f ||
                                        movedX ||
                                        movedY ||
                                        abs(panChange.y) >= abs(panChange.x)
                                    if (shouldConsume) {
                                        event.changes.forEach { if (it.positionChanged()) it.consume() }
                                    }
                                }
                            }
                        } while (!canceled && event.changes.any { it.pressed })

                        if (scale < 1.04f && (scale != 1f || offsetX != 0f || offsetY != 0f)) {
                            animateTransformTo(1f, 0f, 0f)
                        }
                    }
                }
                .pointerInput(asset.id) {
                    detectTapGestures(
                        onTap = { latestToggleChrome() },
                        onDoubleTap = { tapOffset ->
                            if (scale > 1.05f) {
                                animateTransformTo(1f, 0f, 0f)
                            } else {
                                val targetScale = 2.6f
                                val maxX = latestComputeMaxX(targetScale)
                                val maxY = latestComputeMaxY(targetScale)
                                val centerX = size.width / 2f
                                val centerY = size.height / 2f
                                val targetX = ((centerX - tapOffset.x) * (targetScale - 1f)).coerceIn(-maxX, maxX)
                                val targetY = ((centerY - tapOffset.y) * (targetScale - 1f)).coerceIn(-maxY, maxY)
                                animateTransformTo(targetScale, targetX, targetY)
                            }
                        }
                    )
                },
            contentAlignment = Alignment.Center
        ) {
            if (file != null) {
                // Two-layer graphicsLayer keeps screen-space pan & horizontal mirror independent of 90°/270° rotation.
                Box(
                    modifier = Modifier.graphicsLayer {
                        translationX = offsetX
                        translationY = offsetY
                        scaleX = scale * animFlipX
                        scaleY = scale
                    }
                ) {
                    AsyncImage(
                        model = file,
                        contentDescription = asset.title,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .requiredSize(width = animatedWidth, height = animatedHeight)
                            .graphicsLayer {
                                rotationZ = animRotation
                            }
                            .clip(RoundedCornerShape(if (isChromeVisible) 24.dp else 0.dp))
                    )
                }
            } else {
                CharkleExpressiveLoader()
            }
        }
    }
}

/**
 * Reusable 1:1 Single-Asset Inspector Panel powering BOTH Phone Quick Look BottomSheet
 * AND Tablet/Foldable docked 320dp right Inspector pane (`DESIGN.md §7.7`).
 * Protects title/notes drafts against external sync overwrites, debounces auto-save,
 * and flushes pending edits cleanly on dispose.
 */
@Composable
fun AssetInspectorPanel(
    asset: AssetDto,
    activeTab: Int,
    onSelectTab: (Int) -> Unit,
    store: CharkleAppStore,
    onFilterByColor: (String) -> Unit,
    onSelectSimilar: (AssetDto) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val cookieShape = MaterialShapes.Cookie6Sided.toShape()

    var titleDraft by remember(asset.id) { mutableStateOf(asset.title) }
    var notesDraft by remember(asset.id) { mutableStateOf(asset.notes) }
    var lastSyncedTitle by remember(asset.id) { mutableStateOf(asset.title) }
    var lastSyncedNotes by remember(asset.id) { mutableStateOf(asset.notes) }
    var lastSubmittedKey by remember(asset.id) { mutableStateOf<Pair<String, String>?>(null) }
    var newTagDraft by remember(asset.id) { mutableStateOf("") }
    var similarItems by remember(asset.id) { mutableStateOf<List<ScoredAssetDto>?>(null) }

    // Only accept external title/notes updates when the user has not locally modified that field.
    LaunchedEffect(asset.id, asset.title, asset.notes) {
        if (titleDraft == lastSyncedTitle) {
            titleDraft = asset.title
        }
        if (notesDraft == lastSyncedNotes) {
            notesDraft = asset.notes
        }
        lastSyncedTitle = asset.title
        lastSyncedNotes = asset.notes
        if (lastSubmittedKey == (asset.title to asset.notes)) {
            lastSubmittedKey = null
        }
    }

    val trimmedTitle = titleDraft.trim()
    val isTitleInvalid = trimmedTitle.isEmpty()
    val titleChanged = trimmedTitle != asset.title
    val notesChanged = notesDraft != asset.notes
    val isDirty = titleChanged || notesChanged

    fun commitDraftIfNeeded() {
        val cleanTitle = titleDraft.trim()
        val hasTitleChange = cleanTitle.isNotEmpty() && cleanTitle != asset.title
        val hasNotesChange = notesDraft != asset.notes
        if (!hasTitleChange && !hasNotesChange) return
        val submitPair = (if (hasTitleChange) cleanTitle else asset.title) to notesDraft
        if (lastSubmittedKey == submitPair) return
        lastSubmittedKey = submitPair
        store.updateAssetDetails(
            assetId = asset.id,
            title = if (hasTitleChange) cleanTitle else null,
            notes = if (hasNotesChange) notesDraft else null
        )
    }

    // Debounced auto-save so edits persist seamlessly even without pressing the Save button.
    LaunchedEffect(asset.id, titleDraft, notesDraft) {
        if (isDirty && !isTitleInvalid) {
            delay(900)
            commitDraftIfNeeded()
        }
    }

    val latestCommit by rememberUpdatedState(::commitDraftIfNeeded)
    DisposableEffect(asset.id) {
        onDispose {
            latestCommit()
        }
    }

    LaunchedEffect(asset.id, activeTab) {
        if (activeTab == 1 && similarItems == null) {
            similarItems = store.loadSimilarAssets(asset.id)
        }
    }

    fun submitNewTag() {
        val clean = newTagDraft.trim().removePrefix("#").trim()
        if (clean.isEmpty()) return
        val duplicate = asset.tags.any { it.equals(clean, ignoreCase = true) }
        if (duplicate) {
            store.showToast("标签 #$clean 已存在")
            newTagDraft = ""
            return
        }
        store.updateAssetDetails(asset.id, addTags = listOf(clean))
        newTagDraft = ""
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .navigationBarsPadding()
            .imePadding()
            .padding(horizontal = 18.dp, vertical = 8.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = trimmedTitle.ifEmpty { asset.title },
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Spacer(Modifier.width(8.dp))
            CharkleConnectedButtonGroup(
                height = 36.dp,
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                items = listOf(
                    ConnectedActionItem(
                        icon = Icons.Rounded.Info,
                        contentDescription = "信息",
                        label = "信息",
                        checked = activeTab == 0,
                        onClick = { onSelectTab(0) }
                    ),
                    ConnectedActionItem(
                        icon = Icons.Rounded.AutoAwesome,
                        contentDescription = "相似素材",
                        label = "相似",
                        checked = activeTab == 1,
                        onClick = { onSelectTab(1) }
                    )
                )
            )
        }

        if (activeTab == 0) {
            // 1. Dominant Palette Swatches (tap to copy & filter)
            if (asset.dominantColors.isNotEmpty()) {
                SegmentedSection(title = "提取主色板（点按复制并按色筛图）") {
                    SegmentedRowCard(index = 0, count = 1) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            items(asset.dominantColors, key = { it.hex }) { swatch ->
                                val c = parseHexColor(swatch.hex) ?: MaterialTheme.colorScheme.primary
                                val upperHex = swatch.hex.uppercase(Locale.ROOT)
                                Column(
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    modifier = Modifier.clickable {
                                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                        cm?.setPrimaryClip(ClipData.newPlainText("Charkle Color", upperHex))
                                        store.showToast("已复制色值 $upperHex")
                                        onFilterByColor(swatch.hex)
                                    }
                                ) {
                                    Box(
                                        Modifier
                                            .size(38.dp)
                                            .clip(cookieShape)
                                            .background(c)
                                            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, cookieShape)
                                    )
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        upperHex,
                                        style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // 2. Rating & Inline Editable Title / Notes with Draft Safety & Auto-Save
            SegmentedSection(title = "评分与备注") {
                SegmentedRowCard(index = 0, count = 2) {
                    Text(
                        "评分",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.weight(1f))
                    Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                        for (star in 1..5) {
                            IconButton(
                                onClick = {
                                    store.setAssetRating(asset.id, if (asset.rating == star) 0 else star)
                                },
                                modifier = Modifier.size(32.dp)
                            ) {
                                Icon(
                                    imageVector = if (star <= asset.rating) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                                    contentDescription = "$star 星",
                                    tint = if (star <= asset.rating) Color(0xFFE5A93B) else MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                        }
                    }
                }

                SegmentedRowCard(index = 1, count = 2) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        OutlinedTextField(
                            value = titleDraft,
                            onValueChange = { titleDraft = it },
                            label = { Text("标题") },
                            isError = isTitleInvalid,
                            supportingText = if (isTitleInvalid) {
                                { Text("标题不能为空") }
                            } else {
                                null
                            },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = { commitDraftIfNeeded() }),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.fillMaxWidth()
                        )
                        OutlinedTextField(
                            value = notesDraft,
                            onValueChange = { notesDraft = it },
                            label = { Text("备注") },
                            maxLines = 4,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.fillMaxWidth()
                        )
                        if (isDirty) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    text = if (isTitleInvalid) "请输入有效标题" else "停顿或离开时将自动保存",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = if (isTitleInvalid) {
                                        MaterialTheme.colorScheme.error
                                    } else {
                                        MaterialTheme.colorScheme.onSurfaceVariant
                                    }
                                )
                                FilledTonalButton(
                                    enabled = !isTitleInvalid,
                                    onClick = { commitDraftIfNeeded() }
                                ) {
                                    Icon(Icons.Rounded.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("立即保存")
                                }
                            }
                        }
                    }
                }
            }

            // 3. Editable Tags + Suggested Tags
            SegmentedSection(title = "标签管理") {
                SegmentedRowCard(index = 0, count = 1) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        if (asset.tags.isNotEmpty()) {
                            FlowRow(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                asset.tags.forEach { tag ->
                                    InputChip(
                                        selected = true,
                                        onClick = {
                                            store.updateAssetDetails(asset.id, removeTags = listOf(tag))
                                        },
                                        label = { Text("#$tag") },
                                        trailingIcon = {
                                            Icon(
                                                Icons.Rounded.Close,
                                                contentDescription = "移除标签",
                                                modifier = Modifier.size(14.dp)
                                            )
                                        }
                                    )
                                }
                            }
                        }

                        val availableSuggested = remember(asset.suggestedTags, asset.tags) {
                            asset.suggestedTags.filter { cand ->
                                asset.tags.none { it.equals(cand, ignoreCase = true) }
                            }.take(6)
                        }
                        if (availableSuggested.isNotEmpty()) {
                            FlowRow(
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                availableSuggested.forEach { suggested ->
                                    AssistChip(
                                        onClick = {
                                            store.updateAssetDetails(asset.id, addTags = listOf(suggested))
                                        },
                                        leadingIcon = { Icon(Icons.Rounded.Add, null, Modifier.size(14.dp)) },
                                        label = { Text(suggested) }
                                    )
                                }
                            }
                        }

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            OutlinedTextField(
                                value = newTagDraft,
                                onValueChange = { newTagDraft = it },
                                placeholder = { Text("添加新标签…") },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                                keyboardActions = KeyboardActions(onDone = { submitNewTag() }),
                                shape = CircleShape,
                                modifier = Modifier.weight(1f)
                            )
                            IconButton(
                                enabled = newTagDraft.trim().removePrefix("#").isNotEmpty(),
                                onClick = { submitNewTag() }
                            ) {
                                Icon(Icons.Rounded.Add, contentDescription = "添加标签")
                            }
                        }
                    }
                }
            }

            // 4. Core Specs
            val infoRows = buildList {
                add("类型" to asset.displayTypeLabel)
                add("尺寸" to "${asset.pixelWidth} × ${asset.pixelHeight} px")
                if (asset.fileSizeBytes > 0) add("大小" to formatBytes(asset.fileSizeBytes))
                asset.sourceDomain?.takeIf { it.isNotBlank() }?.let { add("来源" to it) }
            }
            SegmentedSection(title = "基础规格") {
                infoRows.forEachIndexed { idx, (k, v) ->
                    SegmentedRowCard(index = idx, count = infoRows.size) {
                        Text(
                            k,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.width(64.dp)
                        )
                        Text(
                            v,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }

            // 5. Camera EXIF (gated by meaningful camera metadata per DESIGN.md §7.7)
            asset.richMetadata?.photoExif?.takeIf { it.hasMeaningfulCameraInfo }?.let { exif ->
                val rows = buildList {
                    listOfNotNull(exif.cameraMake, exif.cameraModel)
                        .joinToString(" ")
                        .takeIf { it.isNotBlank() }
                        ?.let { add("相机" to it) }
                    exif.lensModel?.let { add("镜头" to it) }
                    exif.focalLengthMm?.let { add("焦距" to "${it.toInt()} mm") }
                    exif.apertureFNumber?.let { add("光圈" to "f/$it") }
                    exif.isoSpeed?.let { add("ISO" to it.toString()) }
                }
                if (rows.isNotEmpty()) {
                    SegmentedSection(title = "相机 EXIF") {
                        rows.forEachIndexed { idx, (k, v) ->
                            SegmentedRowCard(index = idx, count = rows.size) {
                                Text(
                                    k,
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.width(64.dp)
                                )
                                Text(v, style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                    }
                }
            }

            // 6. AI Generation Prompt metadata
            asset.richMetadata?.aiGeneration?.takeIf { it.hasContent }?.let { ai ->
                SegmentedSection(title = "AI 生成参数") {
                    SegmentedRowCard(index = 0, count = 1) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            ai.modelName?.let {
                                Text("模型：$it", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                            }
                            ai.prompt?.let {
                                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurface)
                            }
                        }
                    }
                }
            }
        } else {
            val items = similarItems
            if (items == null) {
                Box(Modifier.fillMaxWidth().height(140.dp), contentAlignment = Alignment.Center) {
                    CharkleExpressiveLoader()
                }
            } else if (items.isEmpty()) {
                Text(
                    "暂无足够的视觉相似结果。",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 24.dp)
                )
            } else {
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    contentPadding = PaddingValues(vertical = 4.dp)
                ) {
                    items(items, key = { it.asset.id }) { scored ->
                        SimilarAssetCard(
                            scored = scored,
                            store = store,
                            onClick = { onSelectSimilar(scored.asset) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SimilarAssetCard(
    scored: ScoredAssetDto,
    store: CharkleAppStore,
    onClick: () -> Unit
) {
    val file = rememberAssetThumbnailFile(
        store = store,
        assetId = scored.asset.id,
        updatedAt = scored.asset.updatedAt,
        previewTier = false
    )
    Column(
        modifier = Modifier
            .width(116.dp)
            .clickable(onClick = onClick),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(132.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(MaterialTheme.colorScheme.surfaceContainer)
        ) {
            if (file != null) {
                AsyncImage(
                    model = file,
                    contentDescription = scored.asset.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
        Text(
            text = "${(scored.score * 100).toInt()}% 相似",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun shareLocalFile(context: Context, file: File, mimeType: String, title: String): Boolean {
    return runCatching {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType.ifBlank { "*/*" }
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, title)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(shareIntent, "分享素材"))
        true
    }.getOrDefault(false)
}

private fun openUrlInCustomTab(context: Context, url: String) {
    val parsed = runCatching { Uri.parse(url) }.getOrNull() ?: return
    val launched = runCatching {
        CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, parsed)
        true
    }.getOrDefault(false)
    if (!launched) {
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, parsed))
        }
    }
}

private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return String.format(Locale.US, "%.1f KB", kb)
    val mb = kb / 1024.0
    if (mb < 1024) return String.format(Locale.US, "%.1f MB", mb)
    return String.format(Locale.US, "%.2f GB", mb / 1024.0)
}

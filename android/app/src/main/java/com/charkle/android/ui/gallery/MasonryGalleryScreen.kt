@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.gallery

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.lazy.staggeredgrid.rememberLazyStaggeredGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Label
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AudioFile
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Crop
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Dock
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import com.charkle.android.core.AssetDto
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.CharkleExpressiveLoader
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.EmptyVignetteKind
import com.charkle.android.designsystem.ExpressivePillToggleChip
import com.charkle.android.designsystem.MiniatureEmptyState
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.designsystem.rememberAssetThumbnailFile
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import com.charkle.android.store.LibraryScope
import kotlinx.coroutines.launch
import kotlin.math.abs

private val ArtworkCardShape = RoundedCornerShape(12.dp)
private val SelectedCardInnerShape = RoundedCornerShape(10.dp)

/**
 * Zone A: Pure-image high-density neutral masonry gallery (`#F6F6F5` / `#141517`).
 * Zero text clutter beneath thumbnails; Expressive connected chrome lives cleanly in the top header.
 */
@Composable
fun MasonryGalleryScreen(
    state: CharkleUiState,
    store: CharkleAppStore,
    onOpenDirectory: () -> Unit,
    onOpenFilters: () -> Unit,
    onOpenCapture: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenAsset: (AssetDto) -> Unit,
    isExpandedWidth: Boolean = false,
    isLargeTabletWidth: Boolean = false,
    onToggleTabletInspector: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val haptics = LocalHapticFeedback.current
    val gridState = rememberLazyStaggeredGridState()
    val coroutineScope = rememberCoroutineScope()

    val minCols = if (isExpandedWidth) 2 else 1
    val maxCols = if (isExpandedWidth) 7 else 5
    val activeCols = state.columnCount.coerceIn(minCols, maxCols)
    val latestActiveCols by rememberUpdatedState(activeCols)
    val latestIsMultiSelect by rememberUpdatedState(state.isMultiSelectMode)
    val latestSelectedIds by rememberUpdatedState(state.selectedAssetIds)
    val latestIsExpanded by rememberUpdatedState(isExpandedWidth)

    val cloverShape = MaterialShapes.Clover4Leaf.toShape()

    // Scroll cleanly to revealed asset when returning from Moodboard Studio.
    LaunchedEffect(state.highlightedAssetId, state.assets) {
        val targetId = state.highlightedAssetId ?: return@LaunchedEffect
        val idx = state.assets.indexOfFirst { it.id == targetId }
        if (idx >= 0) {
            gridState.animateScrollToItem(idx)
        }
    }

    val cycleCols = remember(store, isExpandedWidth) {
        {
            val cur = latestActiveCols
            val next = if (isExpandedWidth) {
                when (cur) {
                    2 -> 3
                    3 -> 4
                    4 -> 5
                    5 -> 6
                    else -> 2
                }
            } else {
                when (cur) {
                    2 -> 3
                    3 -> 4
                    4 -> 1
                    else -> 2
                }
            }
            store.setColumnCount(next)
        }
    }

    val headerItems = remember(
        state.criteria.hasVisualFilters,
        state.isTabletInspectorVisible,
        isExpandedWidth,
        onOpenFilters,
        onOpenCapture,
        onOpenSettings,
        onToggleTabletInspector,
        cycleCols
    ) {
        buildList {
            add(
                ConnectedActionItem(
                    icon = Icons.Rounded.FilterList,
                    contentDescription = "色彩与筛选",
                    checked = state.criteria.hasVisualFilters,
                    onClick = onOpenFilters
                )
            )
            add(
                ConnectedActionItem(
                    icon = Icons.Rounded.GridView,
                    contentDescription = "切换瀑布流列数",
                    onClick = cycleCols
                )
            )
            add(
                ConnectedActionItem(
                    icon = Icons.Rounded.Add,
                    contentDescription = "采集素材",
                    onClick = onOpenCapture
                )
            )
            if (isExpandedWidth && onToggleTabletInspector != null) {
                add(
                    ConnectedActionItem(
                        icon = Icons.Rounded.Dock,
                        contentDescription = "开关右侧检查器",
                        checked = state.isTabletInspectorVisible,
                        onClick = onToggleTabletInspector
                    )
                )
            }
            add(
                ConnectedActionItem(
                    icon = Icons.Rounded.Settings,
                    contentDescription = "设置与同步",
                    onClick = onOpenSettings
                )
            )
        }
    }

    val onCardClick = remember(store, onOpenAsset) {
        { asset: AssetDto ->
            if (latestIsMultiSelect) {
                val ids = latestSelectedIds
                if (asset.id in ids && ids.size == 1) {
                    store.toggleMultiSelect(false)
                } else {
                    store.toggleAssetSelection(asset.id)
                    if (latestIsExpanded && asset.id !in ids) {
                        store.selectInspectedAsset(asset.id)
                    }
                }
            } else {
                store.selectInspectedAsset(asset.id)
                onOpenAsset(asset)
            }
        }
    }

    val onCardLongClick = remember(store, haptics) {
        { asset: AssetDto ->
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            val ids = latestSelectedIds
            if (latestIsMultiSelect && asset.id in ids && ids.size == 1) {
                store.toggleMultiSelect(false)
            } else {
                store.toggleAssetSelection(asset.id)
                if (latestIsExpanded && asset.id !in ids) {
                    store.selectInspectedAsset(asset.id)
                }
            }
        }
    }

    val navBarBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        // Neutral top bar with adaptive-width Directory pill + Expressive Connected Action Group
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                Surface(
                    onClick = onOpenDirectory,
                    enabled = !isLargeTabletWidth,
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surfaceContainer
                ) {
                    Row(
                        modifier = Modifier.padding(start = 10.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(7.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(18.dp)
                                .clip(cloverShape)
                                .background(MaterialTheme.colorScheme.primary)
                        )
                        Text(
                            text = state.currentScopeTitle,
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        Text(
                            text = state.assets.size.toString(),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            softWrap = false
                        )
                        if (!isLargeTabletWidth) {
                            Icon(
                                imageVector = Icons.Rounded.KeyboardArrowDown,
                                contentDescription = "切换目录",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                }
            }

            CharkleConnectedButtonGroup(
                height = 40.dp,
                containerColor = MaterialTheme.colorScheme.surfaceContainer,
                contentColor = MaterialTheme.colorScheme.onSurface,
                items = headerItems
            )
        }

        // Expressive Borderless Quick-Filter Pill Strip (Zone A neutral tonal + Studio Cobalt active pill)
        val hasFilters = state.criteria.hasVisualFilters || state.criteria.searchQuery.isNotBlank()
        LazyRow(
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(7.dp)
        ) {
            item(key = "pill_all") {
                ExpressivePillToggleChip(
                    label = "全部",
                    selected = !hasFilters,
                    selectedContainerColor = MaterialTheme.colorScheme.onSurface,
                    selectedContentColor = MaterialTheme.colorScheme.surface,
                    unselectedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    onClick = { store.clearAllFilters() }
                )
            }
            if (state.criteria.searchQuery.isNotBlank()) {
                item(key = "pill_query") {
                    ExpressivePillToggleChip(
                        label = "「${state.criteria.searchQuery}」×",
                        selected = true,
                        onClick = { store.setSearchQuery("") }
                    )
                }
            }
            item(key = "pill_color") {
                val activeHex = state.criteria.selectedColorHex
                ExpressivePillToggleChip(
                    label = activeHex?.uppercase() ?: "按色筛",
                    selected = activeHex != null,
                    leadingIcon = if (activeHex == null) Icons.Rounded.Palette else null,
                    swatchColor = activeHex?.let { parseHexColor(it) },
                    unselectedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    onClick = {
                        if (activeHex != null) store.setColorFilter(null) else onOpenFilters()
                    }
                )
            }
            if (state.criteria.shape != null) {
                item(key = "pill_shape") {
                    val shapeLabel = when (state.criteria.shape) {
                        "landscape" -> "横图"
                        "portrait" -> "竖图"
                        "square" -> "方图"
                        else -> state.criteria.shape
                    }
                    ExpressivePillToggleChip(
                        label = shapeLabel,
                        selected = true,
                        leadingIcon = Icons.Rounded.Crop,
                        onClick = onOpenFilters
                    )
                }
            }
            if (state.criteria.onlyPinnedOffline) {
                item(key = "pill_offline") {
                    ExpressivePillToggleChip(
                        label = "仅离线",
                        selected = true,
                        leadingIcon = Icons.Rounded.PushPin,
                        onClick = onOpenFilters
                    )
                }
            }
            if (state.criteria.tags.isNotEmpty()) {
                item(key = "pill_tags") {
                    val firstTag = state.criteria.tags.first()
                    val label = if (state.criteria.tags.size == 1) {
                        "#$firstTag"
                    } else {
                        "#$firstTag +${state.criteria.tags.size - 1}"
                    }
                    ExpressivePillToggleChip(
                        label = label,
                        selected = true,
                        leadingIcon = Icons.AutoMirrored.Rounded.Label,
                        onClick = onOpenFilters
                    )
                }
            }
            item(key = "pill_starred") {
                val starOn = state.criteria.minRating >= 4
                ExpressivePillToggleChip(
                    label = "高星",
                    selected = starOn,
                    leadingIcon = Icons.Rounded.Star,
                    unselectedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    onClick = { store.setMinRatingFilter(if (starOn) 0 else 4) }
                )
            }
            item(key = "pill_image") {
                val imgOn = "image" in state.criteria.kinds
                ExpressivePillToggleChip(
                    label = "图片",
                    selected = imgOn,
                    leadingIcon = Icons.Rounded.Image,
                    unselectedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    onClick = { store.toggleMediaKindFilter("image") }
                )
            }
            item(key = "pill_video") {
                val vidOn = "video" in state.criteria.kinds
                ExpressivePillToggleChip(
                    label = "视频",
                    selected = vidOn,
                    leadingIcon = Icons.Rounded.Videocam,
                    unselectedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    onClick = { store.toggleMediaKindFilter("video") }
                )
            }
            item(key = "pill_web") {
                val webOn = "webBookmark" in state.criteria.kinds
                ExpressivePillToggleChip(
                    label = "网页",
                    selected = webOn,
                    leadingIcon = Icons.Rounded.Language,
                    unselectedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    onClick = { store.toggleMediaKindFilter("webBookmark") }
                )
            }
        }

        // Pure-image virtualized staggered waterfall
        PullToRefreshBox(
            isRefreshing = state.isSyncing,
            onRefresh = { store.reloadLibrary(quiet = true) },
            modifier = Modifier.weight(1f)
        ) {
            when {
                state.isLoading && state.assets.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CharkleExpressiveLoader()
                    }
                }
                state.assets.isEmpty() -> {
                    val isTrash = state.scope == LibraryScope.Trash
                    val isSmartFolder = state.scope is LibraryScope.SmartFolder
                    val kind = when {
                        hasFilters -> EmptyVignetteKind.NoResults
                        state.scope is LibraryScope.Folder || isSmartFolder -> EmptyVignetteKind.EmptyFolder
                        else -> EmptyVignetteKind.EmptyLibrary
                    }
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(bottom = if (isExpandedWidth) 24.dp else 96.dp + navBarBottom),
                        contentAlignment = Alignment.Center
                    ) {
                        MiniatureEmptyState(
                            kind = kind,
                            title = when {
                                hasFilters -> "没有匹配的素材"
                                isTrash -> "回收站是空的"
                                isSmartFolder -> "暂无符合条件的素材"
                                else -> "这里还没有素材"
                            },
                            subtitle = when {
                                hasFilters -> "试着放宽色彩容差或清除当前筛选条件。"
                                isTrash -> "删除的素材会暂存在这里，支持随时恢复或永久清理。"
                                isSmartFolder -> "当前智能文件夹规则下还没有匹配的灵感素材。"
                                else -> "点击右上角「+」采集图片、链接，或在任意应用中直接分享到 Charkle。"
                            },
                            actionLabel = when {
                                hasFilters -> "清除筛选"
                                isTrash || isSmartFolder -> "返回全部素材"
                                else -> "采集新素材"
                            },
                            onAction = when {
                                hasFilters -> ({ store.clearAllFilters() })
                                isTrash || isSmartFolder -> ({ store.selectScope(LibraryScope.AllItems) })
                                else -> onOpenCapture
                            }
                        )
                    }
                }
                else -> {
                    LazyVerticalStaggeredGrid(
                        state = gridState,
                        columns = StaggeredGridCells.Fixed(activeCols),
                        modifier = Modifier
                            .fillMaxSize()
                            .pointerInput(minCols, maxCols) {
                                awaitEachGesture {
                                    awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                                    var cumulativeZoom = 1f
                                    var curCols = latestActiveCols
                                    var pinching = false
                                    do {
                                        val event = awaitPointerEvent(pass = PointerEventPass.Initial)
                                        val pressedCount = event.changes.count { it.pressed }
                                        if (pressedCount >= 2) {
                                            val zoom = event.calculateZoom()
                                            if (zoom != 1f) {
                                                cumulativeZoom *= zoom
                                                if (!pinching && abs(1f - cumulativeZoom) > 0.04f) {
                                                    pinching = true
                                                    curCols = latestActiveCols
                                                }
                                                if (pinching) {
                                                    event.changes.forEach {
                                                        if (it.positionChanged()) it.consume()
                                                    }
                                                    val nextCols = when {
                                                        cumulativeZoom >= 1.24f && curCols > minCols -> curCols - 1
                                                        cumulativeZoom <= 0.80f && curCols < maxCols -> curCols + 1
                                                        else -> curCols
                                                    }
                                                    if (nextCols != curCols) {
                                                        val visible = gridState.layoutInfo.visibleItemsInfo
                                                        val anchorIdx = visible.getOrNull(visible.size / 2)?.index
                                                        curCols = nextCols
                                                        cumulativeZoom = 1f
                                                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                                                        store.setColumnCount(curCols)
                                                        if (anchorIdx != null && anchorIdx > 0) {
                                                            coroutineScope.launch {
                                                                gridState.scrollToItem(anchorIdx)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        } else {
                                            cumulativeZoom = 1f
                                            pinching = false
                                        }
                                    } while (event.changes.any { it.pressed })
                                }
                            },
                        contentPadding = PaddingValues(
                            start = 10.dp,
                            end = 10.dp,
                            top = 4.dp,
                            bottom = if (isExpandedWidth && !state.isMultiSelectMode) {
                                28.dp + navBarBottom
                            } else {
                                104.dp + navBarBottom
                            }
                        ),
                        verticalItemSpacing = 8.dp,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(
                            items = state.assets,
                            key = { it.id },
                            contentType = { it.mediaKind }
                        ) { asset ->
                            val isCheckedInMultiSelect = state.isMultiSelectMode && asset.id in state.selectedAssetIds
                            val isFocusedHighlight = !state.isMultiSelectMode && (
                                state.highlightedAssetId == asset.id ||
                                    (isExpandedWidth && state.inspectedAssetId == asset.id)
                                )
                            PureArtworkCard(
                                asset = asset,
                                store = store,
                                isCheckedInMultiSelect = isCheckedInMultiSelect,
                                isFocusedHighlight = isFocusedHighlight,
                                isMultiSelectMode = state.isMultiSelectMode,
                                onCardClick = onCardClick,
                                onCardLongClick = onCardLongClick
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PureArtworkCard(
    asset: AssetDto,
    store: CharkleAppStore,
    isCheckedInMultiSelect: Boolean,
    isFocusedHighlight: Boolean,
    isMultiSelectMode: Boolean,
    onCardClick: (AssetDto) -> Unit,
    onCardLongClick: (AssetDto) -> Unit
) {
    val context = LocalContext.current
    val thumbFile = rememberAssetThumbnailFile(
        store = store,
        assetId = asset.id,
        updatedAt = asset.updatedAt,
        previewTier = false
    )
    val placeholderTint = remember(asset.primarySwatchHex) {
        parseHexColor(asset.primarySwatchHex)?.copy(alpha = 0.22f)
    } ?: MaterialTheme.colorScheme.surfaceContainer

    val accent = MaterialTheme.colorScheme.primary
    val showAccentRing = isCheckedInMultiSelect || isFocusedHighlight
    val imageRequest = remember(thumbFile, asset.id, asset.updatedAt, context) {
        thumbFile?.let { file ->
            ImageRequest.Builder(context)
                .data(file)
                .memoryCacheKey("gallery_thumb:${asset.id}:${asset.updatedAt}")
                .build()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(asset.aspectRatio)
            .clip(ArtworkCardShape)
            .background(if (isCheckedInMultiSelect) accent.copy(alpha = 0.14f) else placeholderTint)
            .then(
                if (showAccentRing) {
                    Modifier.border(2.5.dp, accent, ArtworkCardShape)
                } else {
                    Modifier.border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, ArtworkCardShape)
                }
            )
            .semantics {
                if (isMultiSelectMode) {
                    this.selected = isCheckedInMultiSelect
                }
            }
            .combinedClickable(
                role = Role.Button,
                onClick = { onCardClick(asset) },
                onLongClick = { onCardLongClick(asset) }
            )
    ) {
        val innerModifier = if (isCheckedInMultiSelect) {
            Modifier
                .fillMaxSize()
                .padding(4.dp)
                .clip(SelectedCardInnerShape)
        } else {
            Modifier.fillMaxSize()
        }

        if (imageRequest != null) {
            AsyncImage(
                model = imageRequest,
                contentDescription = asset.title,
                contentScale = ContentScale.Crop,
                modifier = innerModifier
            )
        } else {
            val fallbackIcon = when (asset.mediaKind) {
                "video" -> Icons.Rounded.Videocam
                "audio" -> Icons.Rounded.AudioFile
                "webBookmark" -> Icons.Rounded.Language
                "document", "designFile" -> Icons.Rounded.Description
                else -> Icons.Rounded.Image
            }
            Box(innerModifier, contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = fallbackIcon,
                    contentDescription = asset.title,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
                )
            }
        }

        // Minimalist media badge (video / animated GIF)
        if (asset.mediaKind == "video" || asset.mediaKind == "animatedImage") {
            Surface(
                shape = CircleShape,
                color = Color.Black.copy(alpha = 0.60f),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(7.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    if (asset.mediaKind == "video") {
                        Icon(
                            imageVector = Icons.Rounded.PlayArrow,
                            contentDescription = "视频",
                            tint = Color.White,
                            modifier = Modifier.size(12.dp)
                        )
                    } else {
                        Text(
                            text = "GIF",
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.White
                        )
                    }
                }
            }
        }

        // Minimalist star indicator only when rated
        if (asset.rating > 0 && !isMultiSelectMode) {
            Surface(
                shape = CircleShape,
                color = Color.Black.copy(alpha = 0.56f),
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(7.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Star,
                        contentDescription = null,
                        tint = Color(0xFFF2B23E),
                        modifier = Modifier.size(11.dp)
                    )
                    Text(
                        text = asset.rating.toString(),
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White
                    )
                }
            }
        }

        if (isMultiSelectMode) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(8.dp)
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(if (isCheckedInMultiSelect) accent else Color.Black.copy(alpha = 0.42f))
                    .then(
                        if (!isCheckedInMultiSelect) {
                            Modifier.border(1.5.dp, Color.White.copy(alpha = 0.88f), CircleShape)
                        } else {
                            Modifier
                        }
                    ),
                contentAlignment = Alignment.Center
            ) {
                if (isCheckedInMultiSelect) {
                    Icon(
                        imageVector = Icons.Rounded.Check,
                        contentDescription = "已选中",
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(15.dp)
                    )
                }
            }
        }
    }
}

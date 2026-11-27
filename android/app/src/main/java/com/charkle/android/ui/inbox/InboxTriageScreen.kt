@file:OptIn(ExperimentalMaterial3ExpressiveApi::class, ExperimentalMaterial3Api::class)

package com.charkle.android.ui.inbox

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.snap
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.DriveFileMove
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.ColorLens
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Style
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.charkle.android.core.AssetDto
import com.charkle.android.core.FolderSuggestionDto
import com.charkle.android.designsystem.ArtworkDynamicExpressiveTheme
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.CharkleWavyProgress
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.EmptyVignetteKind
import com.charkle.android.designsystem.ExpressiveHeroTransportRow
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.LocalCharkleReduceMotion
import com.charkle.android.designsystem.MiniatureEmptyState
import com.charkle.android.designsystem.SegmentedRowCard
import com.charkle.android.designsystem.SegmentedSection
import com.charkle.android.designsystem.expressiveZoneBBackdropBrush
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.designsystem.rememberAssetPreviewFile
import com.charkle.android.designsystem.rememberAssetThumbnailFile
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState

/**
 * Zone B (Focus Triage) + Zone A (Grid):
 * Full Material 3 Expressive triage stage with rich artwork-driven tonal gradient,
 * 4-tile connected quick strip, wavy progress track, and pill-flanked hero squircle CTA.
 */
@Composable
fun InboxTriageScreen(
    state: CharkleUiState,
    store: CharkleAppStore,
    onOpenAsset: (AssetDto) -> Unit,
    onOpenCapture: () -> Unit,
    onActiveArtworkColorsChanged: (List<String>?) -> Unit = {},
    isExpandedWidth: Boolean = false,
    modifier: Modifier = Modifier
) {
    var isGridMode by remember { mutableStateOf(false) }
    var colorProofing by remember { mutableStateOf(state.defaultColorProofing) }
    var focusedAssetId by remember { mutableStateOf<String?>(null) }
    var lastValidIndex by remember { mutableIntStateOf(0) }
    var showFolderPicker by remember { mutableStateOf(false) }
    var suggestion by remember { mutableStateOf<FolderSuggestionDto?>(null) }

    val inbox = state.inboxAssets
    val safeIndex = remember(inbox, focusedAssetId, lastValidIndex) {
        if (inbox.isEmpty()) {
            0
        } else {
            val byId = focusedAssetId?.let { id -> inbox.indexOfFirst { it.id == id } } ?: -1
            if (byId >= 0) byId else lastValidIndex.coerceIn(0, inbox.lastIndex)
        }
    }
    val activeAsset = inbox.getOrNull(safeIndex)
    val isDark = LocalCharkleExtendedColors.current.isDark
    val reduceMotion = LocalCharkleReduceMotion.current
    val navBarBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

    // Keep active asset anchor and normalized index locked so deletions/insertions never jump unexpectedly.
    LaunchedEffect(activeAsset?.id, safeIndex) {
        focusedAssetId = activeAsset?.id
        lastValidIndex = safeIndex
    }

    // Clear dynamic dock palette whenever leaving Inbox tab.
    DisposableEffect(Unit) {
        onDispose {
            onActiveArtworkColorsChanged(null)
        }
    }

    LaunchedEffect(isGridMode, activeAsset?.id, activeAsset?.dominantColors, inbox.isEmpty(), colorProofing) {
        val hexes = if (!isGridMode && !colorProofing && activeAsset != null) {
            activeAsset.dominantColors.map { it.hex }
        } else {
            null
        }
        onActiveArtworkColorsChanged(hexes)
    }

    // Reset suggestion immediately on asset change (preventing stale folder archive) and refresh when folders mutate.
    LaunchedEffect(activeAsset?.id, state.folders) {
        suggestion = null
        val target = activeAsset ?: return@LaunchedEffect
        val loaded = store.loadFolderSuggestion(target.id)
        if (focusedAssetId == target.id) {
            suggestion = loaded
        }
    }

    // Validate recommendation against live folder list (prevents archived moves to deleted/renamed folders).
    val validSuggestion = remember(suggestion, state.folders) {
        val rec = suggestion ?: return@remember null
        val liveFolder = state.folders.firstOrNull {
            it.id.equals(rec.folderId, ignoreCase = true)
        } ?: return@remember null
        rec.copy(folderId = liveFolder.id, folderName = liveFolder.name)
    }

    if (inbox.isEmpty()) {
        Box(
            modifier = modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .statusBarsPadding()
                .padding(bottom = if (isExpandedWidth) 24.dp + navBarBottom else 96.dp + navBarBottom),
            contentAlignment = Alignment.Center
        ) {
            MiniatureEmptyState(
                kind = EmptyVignetteKind.InboxZero,
                title = "收件箱已清空",
                subtitle = "新采集或从任意应用系统分享存入的灵感会先出现在这里，等待一键归档。",
                actionLabel = "采集新素材",
                onAction = onOpenCapture
            )
        }
        return
    }

    if (isGridMode) {
        val gridCols = state.columnCount.coerceIn(
            if (isExpandedWidth) 2 else 1,
            if (isExpandedWidth) 7 else 5
        )
        Column(
            modifier = modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .statusBarsPadding()
        ) {
            InboxHeaderRow(
                count = inbox.size,
                isGridMode = true,
                colorProofing = colorProofing,
                onToggleColorProofing = { colorProofing = !colorProofing },
                onSelectMode = { isGridMode = it }
            )
            LazyVerticalStaggeredGrid(
                columns = StaggeredGridCells.Fixed(gridCols),
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(
                    start = 10.dp,
                    end = 10.dp,
                    top = 4.dp,
                    bottom = if (isExpandedWidth) 28.dp + navBarBottom else 104.dp + navBarBottom
                ),
                verticalItemSpacing = 8.dp,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(inbox, key = { it.id }, contentType = { it.mediaKind }) { item ->
                    InboxGridCard(
                        item = item,
                        store = store,
                        onClick = { onOpenAsset(item) }
                    )
                }
            }
        }
        return
    }

    // Zone B: Rich Dynamic Artwork-Driven Expressive Focus Triage Deck
    val focused = activeAsset ?: return
    val focusedHexes = remember(focused.id, focused.dominantColors) {
        focused.dominantColors.map { it.hex }
    }

    ArtworkDynamicExpressiveTheme(
        dominantHexes = focusedHexes,
        isDark = isDark,
        colorProofingEnabled = colorProofing
    ) {
        val backdrop = expressiveZoneBBackdropBrush(
            isDark = isDark,
            colorProofingEnabled = colorProofing
        )
        val queueProgress = (safeIndex + 1f) / inbox.size.coerceAtLeast(1).toFloat()

        Column(
            modifier = modifier
                .fillMaxSize()
                .background(backdrop)
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(bottom = if (isExpandedWidth) 20.dp else 94.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            InboxHeaderRow(
                count = inbox.size,
                isGridMode = false,
                colorProofing = colorProofing,
                onToggleColorProofing = { colorProofing = !colorProofing },
                onSelectMode = { isGridMode = it }
            )

            // Full-bleed Expressive Hero Artwork Card with smooth item handoff
            val heroFadeSpec = MaterialTheme.motionScheme.fastEffectsSpec<Float>()
            val heroScaleSpec = MaterialTheme.motionScheme.fastSpatialSpec<Float>()
            AnimatedContent(
                targetState = focused,
                contentKey = { it.id },
                transitionSpec = {
                    if (reduceMotion) {
                        fadeIn(snap()) togetherWith fadeOut(snap())
                    } else {
                        (fadeIn(heroFadeSpec) +
                            scaleIn(
                                initialScale = 0.97f,
                                animationSpec = heroScaleSpec
                            )) togetherWith fadeOut(heroFadeSpec)
                    }
                },
                label = "inboxHeroTransition",
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            ) { heroAsset ->
                val previewFile = rememberAssetPreviewFile(
                    store = store,
                    assetId = heroAsset.id,
                    updatedAt = heroAsset.updatedAt,
                    upgradeToOriginal = true
                )
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clip(RoundedCornerShape(28.dp))
                        .background(MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.48f))
                        .clickable { onOpenAsset(heroAsset) }
                ) {
                    if (previewFile != null) {
                        AsyncImage(
                            model = previewFile,
                            contentDescription = heroAsset.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize()
                        )
                    }

                    // Top-right queue index pill
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.primary.copy(alpha = 0.90f),
                        contentColor = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .padding(14.dp)
                    ) {
                        Text(
                            text = "${safeIndex + 1} / ${inbox.size}",
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier.padding(horizontal = 11.dp, vertical = 5.dp)
                        )
                    }

                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .height(112.dp)
                            .background(
                                Brush.verticalGradient(
                                    colors = listOf(
                                        Color.Transparent,
                                        Color.Black.copy(alpha = 0.28f),
                                        Color.Black.copy(alpha = 0.72f)
                                    )
                                )
                            )
                    )
                    Column(
                        modifier = Modifier
                            .align(Alignment.BottomStart)
                            .padding(18.dp)
                    ) {
                        Text(
                            text = heroAsset.title,
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = "${heroAsset.displayTypeLabel} · ${heroAsset.pixelWidth} × ${heroAsset.pixelHeight}",
                            style = MaterialTheme.typography.labelMedium,
                            color = Color.White.copy(alpha = 0.88f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }

            // Expressive 4-Tile Full-Width Connected Action Strip
            CharkleConnectedButtonGroup(
                height = 46.dp,
                fillWidth = true,
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.padding(horizontal = 16.dp),
                items = listOf(
                    ConnectedActionItem(
                        icon = if (focused.rating > 0) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                        contentDescription = "标星",
                        checked = focused.rating > 0,
                        organicActiveShape = true,
                        onClick = {
                            store.setAssetRating(focused.id, if (focused.rating > 0) 0 else 5)
                        }
                    ),
                    ConnectedActionItem(
                        icon = Icons.Rounded.PushPin,
                        contentDescription = "离线置顶",
                        checked = focused.pinnedOffline,
                        onClick = { store.toggleOfflinePin(focused) }
                    ),
                    ConnectedActionItem(
                        icon = Icons.Rounded.FolderOpen,
                        contentDescription = "选择目录",
                        onClick = { showFolderPicker = true }
                    ),
                    ConnectedActionItem(
                        icon = Icons.Rounded.DeleteOutline,
                        contentDescription = "移至回收站",
                        onClick = { store.trashAssets(listOf(focused.id)) }
                    )
                )
            )

            // Expressive Wavy Queue Progress
            CharkleWavyProgress(
                progress = queueProgress,
                color = MaterialTheme.colorScheme.primary,
                trackColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.16f),
                modifier = Modifier.padding(horizontal = 18.dp)
            )

            // Signature M3 Expressive Hero Triage Row (Pill Flanks + Deep Squircle Primary CTA)
            ExpressiveHeroTransportRow(
                leadingIcon = Icons.Rounded.DeleteOutline,
                leadingDescription = "移至回收站",
                onLeadingClick = { store.trashAssets(listOf(focused.id)) },
                centerIcon = if (validSuggestion != null) {
                    Icons.Rounded.AutoAwesome
                } else {
                    Icons.AutoMirrored.Rounded.DriveFileMove
                },
                centerLabel = if (validSuggestion != null) {
                    "归入「${validSuggestion.folderName}」"
                } else {
                    "归入文件夹"
                },
                onCenterClick = {
                    if (validSuggestion != null) {
                        store.moveAssetsToFolder(
                            listOf(focused.id),
                            validSuggestion.folderId,
                            validSuggestion.folderName
                        )
                    } else {
                        showFolderPicker = true
                    }
                },
                trailingIcon = Icons.Rounded.SkipNext,
                trailingDescription = "下一张",
                trailingEnabled = inbox.size > 1,
                trailingProgress = queueProgress,
                onTrailingClick = {
                    if (inbox.size > 1) {
                        val nextIdx = (safeIndex + 1) % inbox.size
                        lastValidIndex = nextIdx
                        focusedAssetId = inbox[nextIdx].id
                    }
                },
                modifier = Modifier.padding(horizontal = 16.dp)
            )
        }

        if (showFolderPicker) {
            ModalBottomSheet(
                onDismissRequest = { showFolderPicker = false },
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
                    Text("选择目标文件夹", style = MaterialTheme.typography.titleMedium)
                    if (state.folders.isEmpty()) {
                        Text(
                            "还没有文件夹，先去目录抽屉里新建一个吧。",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    } else {
                        SegmentedSection {
                            state.folders.forEachIndexed { idx, folder ->
                                SegmentedRowCard(
                                    index = idx,
                                    count = state.folders.size,
                                    onClick = {
                                        store.moveAssetsToFolder(listOf(focused.id), folder.id, folder.name)
                                        showFolderPicker = false
                                    }
                                ) {
                                    val dotColor = parseHexColor(folder.colorHex) ?: MaterialTheme.colorScheme.primary
                                    Box(
                                        modifier = Modifier
                                            .padding(end = 10.dp)
                                            .size(10.dp)
                                            .clip(CircleShape)
                                            .background(dotColor)
                                    )
                                    Text(
                                        folder.name,
                                        style = MaterialTheme.typography.bodyMedium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Text(
                                        "${folder.assetCount} 项",
                                        style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
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

@Composable
private fun InboxGridCard(
    item: AssetDto,
    store: CharkleAppStore,
    onClick: () -> Unit
) {
    val file = rememberAssetThumbnailFile(
        store = store,
        assetId = item.id,
        updatedAt = item.updatedAt,
        previewTier = false
    )
    val placeholderTint = remember(item.primarySwatchHex) {
        parseHexColor(item.primarySwatchHex)?.copy(alpha = 0.22f)
    } ?: MaterialTheme.colorScheme.surfaceContainer

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(item.aspectRatio)
            .clip(RoundedCornerShape(14.dp))
            .background(placeholderTint)
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
    ) {
        if (file != null) {
            AsyncImage(
                model = file,
                contentDescription = item.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}

@Composable
private fun InboxHeaderRow(
    count: Int,
    isGridMode: Boolean,
    colorProofing: Boolean,
    onToggleColorProofing: () -> Unit,
    onSelectMode: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "收件箱",
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            Text(
                text = "待整理 $count 项",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
                maxLines = 1
            )
        }

        if (!isGridMode) {
            Surface(
                onClick = onToggleColorProofing,
                shape = CircleShape,
                color = if (colorProofing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primaryContainer,
                contentColor = if (colorProofing) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(40.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        Icons.Rounded.ColorLens,
                        contentDescription = if (colorProofing) "恢复作品氛围色" else "原色校对",
                        modifier = Modifier.size(19.dp)
                    )
                }
            }
        }

        CharkleConnectedButtonGroup(
            height = 40.dp,
            containerColor = if (isGridMode) {
                MaterialTheme.colorScheme.surfaceContainerHigh
            } else {
                MaterialTheme.colorScheme.primaryContainer
            },
            contentColor = if (isGridMode) {
                MaterialTheme.colorScheme.onSurface
            } else {
                MaterialTheme.colorScheme.onPrimaryContainer
            },
            items = listOf(
                ConnectedActionItem(
                    icon = Icons.Rounded.Style,
                    contentDescription = "逐张归档",
                    label = "逐张",
                    checked = !isGridMode,
                    onClick = { onSelectMode(false) }
                ),
                ConnectedActionItem(
                    icon = Icons.Rounded.GridView,
                    contentDescription = "瀑布流总览",
                    label = "总览",
                    checked = isGridMode,
                    onClick = { onSelectMode(true) }
                )
            )
        )
    }
}

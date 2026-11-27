@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.shell

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.DriveFileMove
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Dashboard
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Inbox
import androidx.compose.material.icons.rounded.RestoreFromTrash
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.charkle.android.core.AssetDto
import com.charkle.android.designsystem.ArtworkDynamicExpressiveTheme
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.CharkleExpressiveTheme
import com.charkle.android.designsystem.CharkleFloatingNavDock
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.FloatingNavDestination
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.SegmentedRowCard
import com.charkle.android.designsystem.SegmentedSection
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import com.charkle.android.store.LibraryScope
import com.charkle.android.store.PrimaryTab
import com.charkle.android.ui.capture.CaptureSheetContent
import com.charkle.android.ui.detail.AssetDetailScreen
import com.charkle.android.ui.detail.AssetInspectorPanel
import com.charkle.android.ui.gallery.MasonryGalleryScreen
import com.charkle.android.ui.inbox.InboxTriageScreen
import com.charkle.android.ui.moodboard.MoodboardStudioScreen
import com.charkle.android.ui.moodboard.MoodboardsScreen
import com.charkle.android.ui.pinterest.PinterestExploreScreen
import com.charkle.android.ui.search.SearchAndFilterSheetContent
import com.charkle.android.ui.settings.SettingsSheetContent
import com.charkle.android.ui.sidebar.DirectoryDrawerContent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

private enum class DetailSource {
    Library,
    Inbox,
    Custom
}

private data class DetailContext(
    val source: DetailSource,
    val initialAssetId: String,
    val fallbackAssets: List<AssetDto> = emptyList()
)

@Composable
fun AdaptiveRootShell(store: CharkleAppStore) {
    val state by store.state.collectAsState()

    LaunchedEffect(Unit) {
        store.bootstrap()
    }

    var showDirectorySheet by remember { mutableStateOf(false) }
    var showSearchFilterSheet by remember { mutableStateOf(false) }
    var showCaptureSheet by remember { mutableStateOf(false) }
    var showSettingsSheet by remember { mutableStateOf(false) }
    var showBatchMoveSheet by remember { mutableStateOf(false) }
    var activeDetailContext by remember { mutableStateOf<DetailContext?>(null) }
    var customHydratedMap by remember { mutableStateOf<Map<String, AssetDto>>(emptyMap()) }
    var inboxDynamicHexes by remember { mutableStateOf<List<String>?>(null) }
    var sharedInspectorTab by remember { mutableIntStateOf(0) }

    // Always clear Inbox dynamic dock colors when leaving Inbox or when Inbox empties.
    LaunchedEffect(state.activeTab, state.inboxAssets.isEmpty()) {
        if (state.activeTab != PrimaryTab.Inbox || state.inboxAssets.isEmpty()) {
            inboxDynamicHexes = null
        }
    }

    // Keep custom Quick Look assets (e.g. opened via Quick Jump outside current folder) synchronized on mutations.
    LaunchedEffect(activeDetailContext, state.assets, state.inboxAssets) {
        val ctx = activeDetailContext
        if (ctx == null || ctx.source != DetailSource.Custom) {
            customHydratedMap = emptyMap()
            return@LaunchedEffect
        }
        val missingIds = ctx.fallbackAssets.map { it.id }.filter { id ->
            state.assets.none { it.id == id } && state.inboxAssets.none { it.id == id }
        }
        if (missingIds.isEmpty()) return@LaunchedEffect
        val refreshed = withContext(Dispatchers.IO) {
            missingIds.mapNotNull { id ->
                runCatching { store.repository.fetchAsset(id) }.getOrNull()
            }.associateBy { it.id }
        }
        customHydratedMap = refreshed
    }

    LaunchedEffect(state.pendingOpenCapture) {
        if (state.pendingOpenCapture) {
            showCaptureSheet = true
            store.consumePendingOpenCapture()
        }
    }

    LaunchedEffect(state.pendingOpenAssetId, state.assets, state.inboxAssets, state.isLoading) {
        val targetId = state.pendingOpenAssetId ?: return@LaunchedEffect
        when {
            state.assets.any { it.id == targetId } -> {
                activeDetailContext = DetailContext(DetailSource.Library, targetId, state.assets)
                store.consumePendingOpenAsset()
            }
            state.inboxAssets.any { it.id == targetId } -> {
                activeDetailContext = DetailContext(DetailSource.Inbox, targetId, state.inboxAssets)
                store.consumePendingOpenAsset()
            }
            state.isBootstrapped && !state.isLoading -> {
                val fetched = withContext(Dispatchers.IO) {
                    runCatching { store.repository.fetchAsset(targetId) }.getOrNull()
                }
                if (fetched != null) {
                    activeDetailContext = DetailContext(DetailSource.Custom, fetched.id, listOf(fetched))
                }
                store.consumePendingOpenAsset()
            }
        }
    }

    val screenWidthDp = LocalConfiguration.current.screenWidthDp
    val isExpandedWidth = screenWidthDp >= 600
    val isLargeTabletWidth = screenWidthDp >= 900

    // Dismiss floating directory sheet automatically if foldable unfolds to permanent sidebar width.
    LaunchedEffect(isLargeTabletWidth) {
        if (isLargeTabletWidth) {
            showDirectorySheet = false
        }
    }

    // Deterministic BackHandler base layers (full-screen overlays composed later take higher priority).
    BackHandler(enabled = state.activeTab != PrimaryTab.Library) {
        store.selectTab(PrimaryTab.Library)
    }
    BackHandler(enabled = state.isMultiSelectMode) {
        store.toggleMultiSelect(false)
    }

    val openAssetFromSearchOrExternal: (AssetDto) -> Unit = { asset ->
        val inLibrary = state.assets.any { it.id == asset.id }
        activeDetailContext = if (inLibrary) {
            DetailContext(DetailSource.Library, asset.id, state.assets)
        } else {
            DetailContext(DetailSource.Custom, asset.id, listOf(asset))
        }
    }

    val closeFullScreenWorkspaces: () -> Unit = {
        if (state.activeMoodboardId != null) store.closeMoodboard()
        if (state.showPinterestExplore) store.closePinterestExplore()
    }

    CharkleExpressiveTheme(
        appearanceMode = state.appearanceMode,
        followSystemAccentOnControls = state.followSystemAccentOnControls
    ) {
        val isDark = LocalCharkleExtendedColors.current.isDark
        Box(modifier = Modifier.fillMaxSize()) {
            val mainContent: @Composable (Modifier) -> Unit = { contentMod ->
                when (state.activeTab) {
                    PrimaryTab.Library -> MasonryGalleryScreen(
                        state = state,
                        store = store,
                        onOpenDirectory = { showDirectorySheet = true },
                        onOpenFilters = { showSearchFilterSheet = true },
                        onOpenCapture = { showCaptureSheet = true },
                        onOpenSettings = { showSettingsSheet = true },
                        onOpenAsset = { asset ->
                            activeDetailContext = DetailContext(DetailSource.Library, asset.id, state.assets)
                        },
                        isExpandedWidth = isExpandedWidth,
                        isLargeTabletWidth = isLargeTabletWidth,
                        onToggleTabletInspector = { store.toggleTabletInspector() },
                        modifier = contentMod
                    )
                    PrimaryTab.Inbox -> InboxTriageScreen(
                        state = state,
                        store = store,
                        onOpenAsset = { asset ->
                            activeDetailContext = DetailContext(DetailSource.Inbox, asset.id, state.inboxAssets)
                        },
                        onOpenCapture = { showCaptureSheet = true },
                        onActiveArtworkColorsChanged = { inboxDynamicHexes = it },
                        isExpandedWidth = isExpandedWidth,
                        modifier = contentMod
                    )
                    PrimaryTab.Moodboards -> MoodboardsScreen(
                        state = state,
                        store = store,
                        onOpenBoard = { boardId -> store.openMoodboard(boardId) },
                        modifier = contentMod
                    )
                }
            }

            if (isExpandedWidth) {
                // Foldable / Android Tablet 2-pane or 3-pane adaptive workspace
                Row(modifier = Modifier.fillMaxSize()) {
                    NavigationRail(
                        containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                    ) {
                        PrimaryTab.entries.forEach { tab ->
                            val selected = state.activeTab == tab
                            NavigationRailItem(
                                selected = selected,
                                onClick = { store.selectTab(tab) },
                                icon = {
                                    val icon = when (tab) {
                                        PrimaryTab.Library -> if (selected) Icons.Rounded.GridView else Icons.Outlined.GridView
                                        PrimaryTab.Inbox -> if (selected) Icons.Rounded.Inbox else Icons.Outlined.Inbox
                                        PrimaryTab.Moodboards -> if (selected) Icons.Rounded.Dashboard else Icons.Outlined.Dashboard
                                    }
                                    if (tab == PrimaryTab.Inbox && state.inboxCount > 0) {
                                        BadgedBox(
                                            badge = {
                                                Badge(
                                                    containerColor = MaterialTheme.colorScheme.primary,
                                                    contentColor = MaterialTheme.colorScheme.onPrimary
                                                ) {
                                                    Text(if (state.inboxCount > 99) "99+" else state.inboxCount.toString())
                                                }
                                            }
                                        ) {
                                            Icon(icon, contentDescription = tab.label)
                                        }
                                    } else {
                                        Icon(icon, contentDescription = tab.label)
                                    }
                                },
                                label = { Text(tab.label) }
                            )
                        }
                    }

                    if (isLargeTabletWidth && state.activeTab == PrimaryTab.Library) {
                        VerticalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        DirectoryDrawerContent(
                            state = state,
                            store = store,
                            onSelectScope = { store.selectScope(it) },
                            onOpenPinterest = { store.openPinterestExplore() },
                            onOpenSettings = { showSettingsSheet = true },
                            modifier = Modifier
                                .width(264.dp)
                                .fillMaxHeight()
                                .background(MaterialTheme.colorScheme.surfaceContainerLow)
                                .statusBarsPadding()
                                .navigationBarsPadding()
                        )
                    }

                    VerticalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                        mainContent(Modifier.fillMaxSize())

                        if (state.isMultiSelectMode) {
                            MultiSelectBatchBar(
                                state = state,
                                store = store,
                                onRequestBatchMove = { showBatchMoveSheet = true },
                                modifier = Modifier
                                    .align(Alignment.BottomCenter)
                                    .navigationBarsPadding()
                                    .padding(horizontal = 16.dp, vertical = 14.dp)
                            )
                        }
                    }

                    // Synchronized 320dp Docked Right Inspector Pane (1:1 with Multi-Select & Quick Look)
                    val selectedAssets = remember(state.assets, state.selectedAssetIds) {
                        if (state.selectedAssetIds.isEmpty()) {
                            emptyList()
                        } else {
                            state.assets.filter { it.id in state.selectedAssetIds }
                        }
                    }
                    val inspectedAsset = when {
                        state.isMultiSelectMode && selectedAssets.size == 1 -> selectedAssets.first()
                        else -> state.assets.firstOrNull { it.id == state.inspectedAssetId }
                            ?: state.assets.firstOrNull()
                    }
                    val showDockedInspector = state.isTabletInspectorVisible &&
                        state.activeTab == PrimaryTab.Library &&
                        (inspectedAsset != null || (state.isMultiSelectMode && selectedAssets.isNotEmpty()))

                    if (showDockedInspector) {
                        VerticalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        Box(
                            modifier = Modifier
                                .width(320.dp)
                                .fillMaxHeight()
                                .background(MaterialTheme.colorScheme.surfaceContainerLow)
                                .statusBarsPadding()
                        ) {
                            if (state.isMultiSelectMode && selectedAssets.size > 1) {
                                TabletMultiSelectInspectorPane(
                                    selectedAssets = selectedAssets,
                                    isTrashScope = state.scope == LibraryScope.Trash,
                                    onMoveToFolder = { showBatchMoveSheet = true },
                                    onTrashOrRestore = {
                                        val ids = state.selectedAssetIds.toList()
                                        if (state.scope == LibraryScope.Trash) {
                                            store.restoreAssets(ids)
                                            store.toggleMultiSelect(false)
                                        } else {
                                            store.trashAssets(ids)
                                        }
                                    },
                                    onExitMultiSelect = { store.toggleMultiSelect(false) }
                                )
                            } else if (inspectedAsset != null) {
                                AssetInspectorPanel(
                                    asset = inspectedAsset,
                                    activeTab = sharedInspectorTab,
                                    onSelectTab = { sharedInspectorTab = it },
                                    store = store,
                                    onFilterByColor = { store.setColorFilter(it) },
                                    onSelectSimilar = { targetAsset ->
                                        store.selectInspectedAsset(targetAsset.id)
                                        openAssetFromSearchOrExternal(targetAsset)
                                    }
                                )
                            }
                        }
                    }
                }
            } else {
                mainContent(Modifier.fillMaxSize())

                // Phone bottom floating M3 Expressive dual-island dock (or Multi-Select Batch Bar)
                if (state.isMultiSelectMode) {
                    MultiSelectBatchBar(
                        state = state,
                        store = store,
                        onRequestBatchMove = { showBatchMoveSheet = true },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .navigationBarsPadding()
                            .padding(horizontal = 16.dp, vertical = 14.dp)
                    )
                } else {
                    val dockContent: @Composable () -> Unit = {
                        CharkleFloatingNavDock(
                            destinations = listOf(
                                FloatingNavDestination(
                                    id = PrimaryTab.Library.id,
                                    label = "素材库",
                                    icon = Icons.Outlined.GridView,
                                    activeIcon = Icons.Rounded.GridView
                                ),
                                FloatingNavDestination(
                                    id = PrimaryTab.Inbox.id,
                                    label = "收件箱",
                                    icon = Icons.Outlined.Inbox,
                                    activeIcon = Icons.Rounded.Inbox,
                                    badgeCount = state.inboxCount
                                ),
                                FloatingNavDestination(
                                    id = PrimaryTab.Moodboards.id,
                                    label = "情绪板",
                                    icon = Icons.Outlined.Dashboard,
                                    activeIcon = Icons.Rounded.Dashboard
                                )
                            ),
                            activeId = state.activeTab.id,
                            onSelect = { id ->
                                PrimaryTab.entries.firstOrNull { it.id == id }?.let { store.selectTab(it) }
                            },
                            onReselectLibrary = { showDirectorySheet = true },
                            companionIcon = Icons.Rounded.Search,
                            companionDescription = "搜图与色彩筛选",
                            companionActive = state.criteria.hasVisualFilters || state.criteria.searchQuery.isNotBlank(),
                            onCompanionClick = { showSearchFilterSheet = true },
                            modifier = Modifier
                                .align(Alignment.BottomCenter)
                                .navigationBarsPadding()
                                .padding(bottom = 14.dp)
                        )
                    }
                    val activeInboxHexes = if (
                        state.activeTab == PrimaryTab.Inbox &&
                        state.inboxAssets.isNotEmpty() &&
                        !inboxDynamicHexes.isNullOrEmpty()
                    ) {
                        inboxDynamicHexes
                    } else {
                        null
                    }
                    if (activeInboxHexes != null) {
                        ArtworkDynamicExpressiveTheme(
                            dominantHexes = activeInboxHexes,
                            isDark = isDark,
                            content = dockContent
                        )
                    } else {
                        dockContent()
                    }
                }
            }

            // Full-Screen Interactive Moodboard Studio Overlay
            state.activeMoodboardId?.let { activeBoardId ->
                MoodboardStudioScreen(
                    boardId = activeBoardId,
                    state = state,
                    store = store,
                    onClose = { store.closeMoodboard() },
                    onOpenAsset = openAssetFromSearchOrExternal,
                    onRevealAssetInLibrary = { assetId ->
                        store.revealAssetFromMoodboard(assetId, activeBoardId)
                    }
                )
            }

            // Full-Screen Pinterest Infinite 2D Spatial Explorer
            if (state.showPinterestExplore) {
                PinterestExploreScreen(
                    state = state,
                    store = store,
                    onClose = { store.closePinterestExplore() }
                )
            }

            // Full-Screen Zone B Artwork-Colored Quick Look Overlay (backed by live asset state)
            activeDetailContext?.let { detailCtx ->
                val liveById = remember(state.assets, state.inboxAssets, customHydratedMap) {
                    buildMap(state.assets.size + state.inboxAssets.size + customHydratedMap.size) {
                        customHydratedMap.forEach { (k, v) -> put(k, v) }
                        state.inboxAssets.forEach { put(it.id, it) }
                        state.assets.forEach { put(it.id, it) }
                    }
                }
                val liveAssets = remember(detailCtx, state.assets, state.inboxAssets, liveById, state.isLoading) {
                    when (detailCtx.source) {
                        DetailSource.Library -> {
                            if (state.assets.isEmpty() && state.isLoading) detailCtx.fallbackAssets else state.assets
                        }
                        DetailSource.Inbox -> state.inboxAssets
                        DetailSource.Custom -> {
                            detailCtx.fallbackAssets.mapNotNull { orig ->
                                val fresh = liveById[orig.id] ?: orig
                                if (!orig.isTrashed && fresh.isTrashed) null else fresh
                            }
                        }
                    }
                }

                AssetDetailScreen(
                    assets = liveAssets,
                    initialAssetId = detailCtx.initialAssetId,
                    state = state,
                    store = store,
                    onDismiss = { activeDetailContext = null },
                    onFilterByColor = { hex ->
                        closeFullScreenWorkspaces()
                        store.selectTab(PrimaryTab.Library)
                        store.setColorFilter(hex)
                    },
                    inspectorTab = sharedInspectorTab,
                    onSelectInspectorTab = { sharedInspectorTab = it },
                    onOpenExternalAsset = { target ->
                        activeDetailContext = DetailContext(DetailSource.Custom, target.id, listOf(target))
                    }
                )
            }

            // Interruptible Expressive Toast Banner (always topmost above full-screen overlays, safe-area aware)
            val hasFullScreenOverlay = activeDetailContext != null ||
                state.activeMoodboardId != null ||
                state.showPinterestExplore

            AnimatedVisibility(
                visible = state.toast != null,
                enter = fadeIn() + slideInVertically { if (hasFullScreenOverlay) -it / 2 else it / 2 },
                exit = fadeOut() + slideOutVertically { if (hasFullScreenOverlay) -it / 2 else it / 2 },
                modifier = Modifier
                    .align(if (hasFullScreenOverlay) Alignment.TopCenter else Alignment.BottomCenter)
                    .then(
                        if (hasFullScreenOverlay) {
                            Modifier
                                .statusBarsPadding()
                                .padding(top = 66.dp, start = 20.dp, end = 20.dp)
                        } else {
                            Modifier
                                .navigationBarsPadding()
                                .imePadding()
                                .padding(
                                    horizontal = 20.dp,
                                    vertical = if (isExpandedWidth && !state.isMultiSelectMode) 24.dp else 92.dp
                                )
                        }
                    )
            ) {
                state.toast?.let { toast ->
                    val actionLabel = toast.actionLabel
                    val onAction = toast.onAction
                    val hasAction = actionLabel != null && onAction != null
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.inverseSurface,
                        contentColor = MaterialTheme.colorScheme.inverseOnSurface,
                        shadowElevation = 6.dp,
                        modifier = Modifier.widthIn(max = 440.dp)
                    ) {
                        Row(
                            modifier = Modifier.padding(
                                start = 18.dp,
                                end = if (hasAction) 8.dp else 18.dp,
                                top = if (hasAction) 4.dp else 10.dp,
                                bottom = if (hasAction) 4.dp else 10.dp
                            ),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Text(
                                text = toast.message,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f, fill = false)
                            )
                            if (actionLabel != null && onAction != null) {
                                TextButton(
                                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                    onClick = {
                                        onAction()
                                        store.dismissToast()
                                    }
                                ) {
                                    Text(
                                        text = actionLabel,
                                        color = MaterialTheme.colorScheme.inversePrimary,
                                        maxLines = 1
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Modal Bottom Sheets
            if (showDirectorySheet) {
                ModalBottomSheet(
                    onDismissRequest = { showDirectorySheet = false },
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ) {
                    DirectoryDrawerContent(
                        state = state,
                        store = store,
                        onSelectScope = { newScope ->
                            store.selectScope(newScope)
                            showDirectorySheet = false
                        },
                        onOpenPinterest = {
                            showDirectorySheet = false
                            store.openPinterestExplore()
                        },
                        onOpenSettings = {
                            showDirectorySheet = false
                            showSettingsSheet = true
                        }
                    )
                }
            }

            if (showSearchFilterSheet) {
                ModalBottomSheet(
                    onDismissRequest = { showSearchFilterSheet = false },
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ) {
                    SearchAndFilterSheetContent(
                        state = state,
                        store = store,
                        onJumpToFolder = { fid ->
                            closeFullScreenWorkspaces()
                            store.selectScope(LibraryScope.Folder(fid))
                        },
                        onJumpToTag = { tag ->
                            closeFullScreenWorkspaces()
                            store.selectScope(LibraryScope.Tag(tag))
                        },
                        onOpenAsset = openAssetFromSearchOrExternal,
                        onOpenPinterest = { store.openPinterestExplore() },
                        onDone = { showSearchFilterSheet = false }
                    )
                }
            }

            if (showCaptureSheet) {
                ModalBottomSheet(
                    onDismissRequest = { showCaptureSheet = false },
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ) {
                    CaptureSheetContent(
                        state = state,
                        store = store,
                        onDone = { showCaptureSheet = false }
                    )
                }
            }

            if (showSettingsSheet) {
                ModalBottomSheet(
                    onDismissRequest = { showSettingsSheet = false },
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ) {
                    SettingsSheetContent(
                        state = state,
                        store = store,
                        onDone = { showSettingsSheet = false }
                    )
                }
            }

            if (showBatchMoveSheet) {
                val targetIds = state.selectedAssetIds.toList()
                ModalBottomSheet(
                    onDismissRequest = { showBatchMoveSheet = false },
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
                        Text(
                            text = "移动已选的 ${targetIds.size} 项素材",
                            style = MaterialTheme.typography.titleMedium
                        )
                        val rows = listOf<Triple<String?, String, String?>>(Triple(null, "收件箱", null)) +
                            state.folders.map { Triple(it.id, it.name, it.colorHex) }
                        SegmentedSection {
                            rows.forEachIndexed { idx, (fid, name, colorHex) ->
                                SegmentedRowCard(
                                    index = idx,
                                    count = rows.size,
                                    onClick = {
                                        store.moveAssetsToFolder(targetIds, fid, name)
                                        showBatchMoveSheet = false
                                    }
                                ) {
                                    if (fid != null) {
                                        val dotColor = parseHexColor(colorHex) ?: MaterialTheme.colorScheme.primary
                                        Box(
                                            modifier = Modifier
                                                .padding(end = 10.dp)
                                                .size(10.dp)
                                                .clip(CircleShape)
                                                .background(dotColor)
                                        )
                                    }
                                    Text(
                                        text = name,
                                        style = MaterialTheme.typography.bodyMedium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
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
private fun MultiSelectBatchBar(
    state: CharkleUiState,
    store: CharkleAppStore,
    onRequestBatchMove: () -> Unit,
    modifier: Modifier = Modifier
) {
    val isDark = LocalCharkleExtendedColors.current.isDark
    val count = state.selectedAssetIds.size
    val isTrashScope = state.scope == LibraryScope.Trash

    Surface(
        shape = CircleShape,
        color = if (isDark) {
            MaterialTheme.colorScheme.surfaceContainerHigh
        } else {
            MaterialTheme.colorScheme.surfaceContainerLowest
        },
        contentColor = MaterialTheme.colorScheme.onSurface,
        shadowElevation = 10.dp,
        modifier = modifier
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = "已选 $count 项",
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.padding(start = 6.dp)
            )
            CharkleConnectedButtonGroup(
                height = 40.dp,
                items = buildList {
                    if (isTrashScope) {
                        add(
                            ConnectedActionItem(
                                icon = Icons.Rounded.RestoreFromTrash,
                                contentDescription = "恢复所选素材",
                                label = "恢复",
                                emphasized = count > 0,
                                onClick = {
                                    if (count > 0) {
                                        store.restoreAssets(state.selectedAssetIds.toList())
                                        store.toggleMultiSelect(false)
                                    }
                                }
                            )
                        )
                    } else {
                        add(
                            ConnectedActionItem(
                                icon = Icons.AutoMirrored.Rounded.DriveFileMove,
                                contentDescription = "移动到文件夹",
                                onClick = {
                                    if (count > 0) onRequestBatchMove()
                                }
                            )
                        )
                        add(
                            ConnectedActionItem(
                                icon = Icons.Rounded.DeleteOutline,
                                contentDescription = "移至回收站",
                                onClick = {
                                    if (count > 0) store.trashAssets(state.selectedAssetIds.toList())
                                }
                            )
                        )
                    }
                    add(
                        ConnectedActionItem(
                            icon = Icons.Rounded.Close,
                            contentDescription = "退出多选",
                            onClick = { store.toggleMultiSelect(false) }
                        )
                    )
                }
            )
        }
    }
}

@Composable
private fun TabletMultiSelectInspectorPane(
    selectedAssets: List<AssetDto>,
    isTrashScope: Boolean,
    onMoveToFolder: () -> Unit,
    onTrashOrRestore: () -> Unit,
    onExitMultiSelect: () -> Unit
) {
    val totalBytes = remember(selectedAssets) { selectedAssets.sumOf { it.fileSizeBytes } }
    val kindsSummary = remember(selectedAssets) {
        selectedAssets.groupingBy { it.displayTypeLabel }
            .eachCount()
            .entries
            .sortedByDescending { it.value }
            .take(3)
            .joinToString(" · ") { "${it.key} ${it.value}" }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .navigationBarsPadding()
            .padding(horizontal = 18.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "已选择 ${selectedAssets.size} 项素材",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f)
            )
            TextButton(onClick = onExitMultiSelect) {
                Text("完成")
            }
        }

        SegmentedSection(title = "批量摘要") {
            SegmentedRowCard(index = 0, count = 2) {
                Text(
                    "类型分布",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(68.dp)
                )
                Text(
                    kindsSummary.ifBlank { "多选素材" },
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )
            }
            SegmentedRowCard(index = 1, count = 2) {
                Text(
                    "总体积",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(68.dp)
                )
                Text(
                    formatSelectionBytes(totalBytes),
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }

        SegmentedSection(title = "批量操作") {
            if (!isTrashScope) {
                SegmentedRowCard(index = 0, count = 2, onClick = onMoveToFolder) {
                    Icon(
                        Icons.AutoMirrored.Rounded.DriveFileMove,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Text("移动到文件夹", style = MaterialTheme.typography.bodyMedium)
                }
                SegmentedRowCard(index = 1, count = 2, onClick = onTrashOrRestore) {
                    Icon(
                        Icons.Rounded.DeleteOutline,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        "移至回收站",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error
                    )
                }
            } else {
                SegmentedRowCard(index = 0, count = 1, onClick = onTrashOrRestore) {
                    Icon(
                        Icons.Rounded.RestoreFromTrash,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Text("恢复所选素材", style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

private fun formatSelectionBytes(bytes: Long): String {
    if (bytes <= 0L) return "—"
    if (bytes < 1024L) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024.0) return String.format(Locale.US, "%.1f KB", kb)
    val mb = kb / 1024.0
    if (mb < 1024.0) return String.format(Locale.US, "%.1f MB", mb)
    return String.format(Locale.US, "%.2f GB", mb / 1024.0)
}

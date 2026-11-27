@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.moodboard

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AutoAwesomeMosaic
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.DriveFileRenameOutline
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.charkle.android.core.MoodboardSummaryDto
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.EmptyVignetteKind
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.MiniatureEmptyState
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun MoodboardsScreen(
    state: CharkleUiState,
    store: CharkleAppStore,
    onOpenBoard: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    var showCreateDialog by remember { mutableStateOf(false) }
    var newBoardTitle by remember { mutableStateOf("") }
    var renamingBoard by remember { mutableStateOf<MoodboardSummaryDto?>(null) }
    var renameDraft by remember { mutableStateOf("") }
    var deletingBoard by remember { mutableStateOf<MoodboardSummaryDto?>(null) }
    val thumbFileCache = remember { mutableStateMapOf<String, File>() }

    fun submitCreateBoard() {
        val clean = newBoardTitle.trim().ifEmpty { "未命名情绪板" }
        store.createMoodboard(clean, openImmediately = true)
        showCreateDialog = false
    }

    fun submitRenameBoard(target: MoodboardSummaryDto) {
        val clean = renameDraft.trim()
        if (clean.isEmpty()) return
        store.renameMoodboard(target.id, clean)
        renamingBoard = null
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text("情绪板", style = MaterialTheme.typography.headlineSmall)
                Text(
                    "支持自由画布、自动杂志排版与 Figma (.charkleboard) 导出",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Spacer(Modifier.width(8.dp))
            FilledTonalButton(
                onClick = {
                    newBoardTitle = ""
                    showCreateDialog = true
                },
                shape = CircleShape
            ) {
                Icon(Icons.Rounded.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text("新建")
            }
        }

        if (state.boards.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    MiniatureEmptyState(
                        kind = EmptyVignetteKind.EmptyMoodboard,
                        title = "还没有情绪板",
                        subtitle = "创建一个情绪板，自由拼贴灵感素材、色板、便签与手写批注，并与 Mac / Windows 双向无损同步。"
                    )
                    Spacer(Modifier.height(14.dp))
                    Button(
                        onClick = {
                            newBoardTitle = ""
                            showCreateDialog = true
                        },
                        shape = CircleShape
                    ) {
                        Icon(Icons.Rounded.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("创建第一个情绪板")
                    }
                }
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 172.dp),
                contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 4.dp, bottom = 112.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.weight(1f)
            ) {
                items(state.boards, key = { it.id }) { board ->
                    MoodboardCard(
                        board = board,
                        thumbFileCache = thumbFileCache,
                        store = store,
                        onOpen = { onOpenBoard(board.id) },
                        onRename = {
                            renamingBoard = board
                            renameDraft = board.title
                        },
                        onTogglePin = { store.toggleMoodboardPinnedOffline(board.id, !board.pinnedOffline) },
                        onDelete = { deletingBoard = board }
                    )
                }
            }
        }
    }

    if (showCreateDialog) {
        AlertDialog(
            onDismissRequest = { showCreateDialog = false },
            title = { Text("新建情绪板") },
            text = {
                OutlinedTextField(
                    value = newBoardTitle,
                    onValueChange = { newBoardTitle = it },
                    placeholder = { Text("例如：陶土陶瓷光影 / 杂志排版") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submitCreateBoard() }),
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(onClick = { submitCreateBoard() }) { Text("创建并进入") }
            },
            dismissButton = {
                TextButton(onClick = { showCreateDialog = false }) { Text("取消") }
            }
        )
    }

    renamingBoard?.let { target ->
        AlertDialog(
            onDismissRequest = { renamingBoard = null },
            title = { Text("重命名情绪板") },
            text = {
                OutlinedTextField(
                    value = renameDraft,
                    onValueChange = { renameDraft = it },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submitRenameBoard(target) }),
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(
                    onClick = { submitRenameBoard(target) },
                    enabled = renameDraft.isNotBlank()
                ) { Text("保存") }
            },
            dismissButton = {
                TextButton(onClick = { renamingBoard = null }) { Text("取消") }
            }
        )
    }

    deletingBoard?.let { target ->
        AlertDialog(
            onDismissRequest = { deletingBoard = null },
            title = { Text("删除情绪板") },
            text = { Text("确认删除「${target.title}」？原素材库中的图片文件不会被删除。") },
            confirmButton = {
                Button(
                    onClick = {
                        store.deleteMoodboard(target.id)
                        deletingBoard = null
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError
                    )
                ) { Text("删除情绪板") }
            },
            dismissButton = {
                TextButton(onClick = { deletingBoard = null }) { Text("取消") }
            }
        )
    }
}

@Composable
private fun MoodboardCard(
    board: MoodboardSummaryDto,
    thumbFileCache: MutableMap<String, File>,
    store: CharkleAppStore,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onTogglePin: () -> Unit,
    onDelete: () -> Unit
) {
    val isDark = LocalCharkleExtendedColors.current.isDark
    val previewIds = remember(board.previewAssetIDs) { board.previewAssetIDs.take(3) }
    var previewFiles by remember(previewIds) {
        mutableStateOf(previewIds.mapNotNull { thumbFileCache[it.uppercase()] })
    }

    LaunchedEffect(previewIds) {
        if (previewIds.isEmpty()) {
            previewFiles = emptyList()
            return@LaunchedEffect
        }
        val missing = previewIds.filter { thumbFileCache[it.uppercase()] == null }
        if (missing.isNotEmpty()) {
            val resolved = withContext(Dispatchers.IO) {
                missing.mapNotNull { id ->
                    store.thumbnailFile(id)?.let { id.uppercase() to it }
                }
            }
            resolved.forEach { (k, f) -> thumbFileCache[k] = f }
        }
        previewFiles = previewIds.mapNotNull { thumbFileCache[it.uppercase()] }
    }

    val tintAccent = remember(board.paletteHexes) {
        board.paletteHexes.firstOrNull()?.let { parseHexColor(it) }
    }
    val cookieShape = MaterialShapes.Cookie6Sided.toShape()
    var menuExpanded by remember { mutableStateOf(false) }

    val cardSurface = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainer
    } else {
        MaterialTheme.colorScheme.surfaceContainerLowest
    }
    val overlayButtonSurface = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.92f)
    } else {
        MaterialTheme.colorScheme.surfaceContainerLowest.copy(alpha = 0.92f)
    }

    Surface(
        shape = RoundedCornerShape(20.dp),
        color = cardSurface,
        tonalElevation = 1.dp,
        modifier = Modifier
            .fillMaxWidth()
            .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(20.dp))
            .clip(RoundedCornerShape(20.dp))
            .clickable(onClick = onOpen)
    ) {
        Column {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(1.25f)
                    .background(
                        tintAccent?.copy(alpha = if (isDark) 0.20f else 0.14f)
                            ?: if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainer
                    )
            ) {
                when {
                    previewFiles.size >= 3 -> {
                        Row(
                            modifier = Modifier.fillMaxSize(),
                            horizontalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            AsyncImage(
                                model = previewFiles[0],
                                contentDescription = board.title,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.weight(1.2f).fillMaxHeight()
                            )
                            Column(
                                modifier = Modifier.weight(1f).fillMaxHeight(),
                                verticalArrangement = Arrangement.spacedBy(2.dp)
                            ) {
                                AsyncImage(
                                    model = previewFiles[1],
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.weight(1f).fillMaxWidth()
                                )
                                AsyncImage(
                                    model = previewFiles[2],
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.weight(1f).fillMaxWidth()
                                )
                            }
                        }
                    }
                    previewFiles.size == 2 -> {
                        Row(
                            modifier = Modifier.fillMaxSize(),
                            horizontalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            previewFiles.forEach { file ->
                                AsyncImage(
                                    model = file,
                                    contentDescription = board.title,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.weight(1f).fillMaxHeight()
                                )
                            }
                        }
                    }
                    previewFiles.size == 1 -> {
                        AsyncImage(
                            model = previewFiles[0],
                            contentDescription = board.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize()
                        )
                    }
                    else -> {
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Icon(
                                Icons.Rounded.AutoAwesomeMosaic,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f),
                                modifier = Modifier.size(34.dp)
                            )
                        }
                    }
                }

                if (board.pinnedOffline) {
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.92f),
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .padding(8.dp)
                    ) {
                        Icon(
                            Icons.Rounded.PushPin,
                            contentDescription = "已离线置顶",
                            tint = MaterialTheme.colorScheme.onPrimaryContainer,
                            modifier = Modifier.padding(5.dp).size(13.dp)
                        )
                    }
                }

                Box(modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp)) {
                    CharkleConnectedButtonGroup(
                        height = 34.dp,
                        containerColor = overlayButtonSurface,
                        contentColor = MaterialTheme.colorScheme.onSurface,
                        items = listOf(
                            ConnectedActionItem(
                                icon = Icons.Rounded.PlayArrow,
                                contentDescription = "打开情绪板",
                                onClick = onOpen
                            ),
                            ConnectedActionItem(
                                icon = Icons.Rounded.MoreVert,
                                contentDescription = "更多操作",
                                onClick = { menuExpanded = true }
                            )
                        )
                    )
                    DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                        DropdownMenuItem(
                            text = { Text("重命名") },
                            leadingIcon = { Icon(Icons.Rounded.DriveFileRenameOutline, null) },
                            onClick = { menuExpanded = false; onRename() }
                        )
                        DropdownMenuItem(
                            text = { Text(if (board.pinnedOffline) "取消离线置顶" else "离线置顶") },
                            leadingIcon = { Icon(Icons.Rounded.PushPin, null) },
                            onClick = { menuExpanded = false; onTogglePin() }
                        )
                        DropdownMenuItem(
                            text = { Text("删除情绪板", color = MaterialTheme.colorScheme.error) },
                            leadingIcon = { Icon(Icons.Rounded.DeleteOutline, null, tint = MaterialTheme.colorScheme.error) },
                            onClick = { menuExpanded = false; onDelete() }
                        )
                    }
                }
            }
            Column(modifier = Modifier.padding(14.dp)) {
                Text(
                    text = board.title,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Spacer(Modifier.height(6.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = "${board.itemCount} 个元素",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        board.paletteHexes.take(4).forEach { hex ->
                            parseHexColor(hex)?.let { c ->
                                Box(
                                    Modifier
                                        .size(13.dp)
                                        .clip(cookieShape)
                                        .background(c)
                                        .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant, cookieShape)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

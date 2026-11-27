package com.charkle.android.ui.sidebar

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Clear
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.charkle.android.core.FolderDto
import com.charkle.android.core.SmartFolderDto
import com.charkle.android.core.SmartFolderRuleDto
import com.charkle.android.designsystem.CharkleDuotoneIcon
import com.charkle.android.designsystem.CharklePaletteTokens
import com.charkle.android.designsystem.ExpressivePillToggleChip
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.SegmentedRowCard
import com.charkle.android.designsystem.SegmentedSection
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import com.charkle.android.store.LibraryScope

private data class FolderTreeNode(
    val folder: FolderDto,
    val depth: Int,
    val children: List<FolderTreeNode>
)

private fun buildFolderForest(folders: List<FolderDto>): List<FolderTreeNode> {
    val byParent = folders.groupBy { it.parentId?.uppercase() }
    val knownIds = folders.map { it.id.uppercase() }.toSet()
    val visited = mutableSetOf<String>()

    fun build(list: List<FolderDto>, depth: Int): List<FolderTreeNode> {
        return list.sortedWith(compareBy<FolderDto> { it.sortOrder }.thenBy { it.name.lowercase() })
            .mapNotNull { folder ->
                val normId = folder.id.uppercase()
                if (!visited.add(normId)) return@mapNotNull null
                FolderTreeNode(
                    folder = folder,
                    depth = depth,
                    children = build(byParent[normId].orEmpty(), depth + 1)
                )
            }
    }

    val roots = folders.filter { f ->
        val p = f.parentId?.uppercase()
        p == null || p !in knownIds
    }
    val primaryTree = build(roots, 0)
    // Cycle-safe fallback: never silently drop folders participating in a corrupted parent cycle
    val remaining = folders.filter { it.id.uppercase() !in visited }
    return if (remaining.isEmpty()) primaryTree else primaryTree + build(remaining, 0)
}

private fun findAncestorIds(folders: List<FolderDto>, targetId: String): Set<String> {
    val byId = folders.associateBy { it.id.uppercase() }
    val ancestors = mutableSetOf<String>()
    var current = byId[targetId.uppercase()]?.parentId?.uppercase()
    var guard = 0
    while (current != null && guard < 64) {
        val parent = byId[current] ?: break
        if (!ancestors.add(parent.id)) break
        current = parent.parentId?.uppercase()
        guard++
    }
    return ancestors
}

private fun countDescendants(node: FolderTreeNode): Int {
    var total = node.children.size
    for (child in node.children) {
        total += countDescendants(child)
    }
    return total
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DirectoryDrawerContent(
    state: CharkleUiState,
    store: CharkleAppStore,
    onSelectScope: (LibraryScope) -> Unit,
    onOpenPinterest: () -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier
) {
    val isDark = LocalCharkleExtendedColors.current.isDark
    val cardSurface = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh
    } else {
        MaterialTheme.colorScheme.surfaceContainerLowest
    }

    var quickFilter by remember { mutableStateOf("") }
    var expandedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var createParentId by remember { mutableStateOf<String?>(null) }
    var showCreateFolder by remember { mutableStateOf(false) }
    var newFolderName by remember { mutableStateOf("") }
    var editingFolder by remember { mutableStateOf<FolderDto?>(null) }
    var deletingFolder by remember { mutableStateOf<FolderDto?>(null) }

    val forest = remember(state.folders) { buildFolderForest(state.folders) }
    val nodeById = remember(forest) {
        val map = mutableMapOf<String, FolderTreeNode>()
        fun index(nodes: List<FolderTreeNode>) {
            for (n in nodes) {
                map[n.folder.id.uppercase()] = n
                index(n.children)
            }
        }
        index(forest)
        map
    }
    val query = quickFilter.trim()

    // Auto-expand ancestor chain whenever the active scope points to a nested folder
    LaunchedEffect(state.scope, state.folders) {
        val activeFolderId = (state.scope as? LibraryScope.Folder)?.folderId ?: return@LaunchedEffect
        val ancestors = findAncestorIds(state.folders, activeFolderId)
        if (ancestors.isNotEmpty()) {
            expandedIds = expandedIds + ancestors
        }
    }

    val visibleFolderRows = remember(forest, expandedIds, query) {
        val out = mutableListOf<FolderTreeNode>()
        fun walk(nodes: List<FolderTreeNode>) {
            for (n in nodes) {
                val matchesSelf = query.isEmpty() || n.folder.name.contains(query, ignoreCase = true)
                val hasMatchingDesc = query.isNotEmpty() && containsQuery(n.children, query)
                if (matchesSelf || hasMatchingDesc) {
                    out.add(n)
                    if (n.children.isNotEmpty() && (query.isNotEmpty() || n.folder.id in expandedIds)) {
                        walk(n.children)
                    }
                }
            }
        }
        walk(forest)
        out
    }

    val filteredSmartFolders = remember(state.smartFolders, query) {
        val sorted = state.smartFolders.sortedWith(
            compareBy<SmartFolderDto> { it.sortOrder }.thenBy { it.name.lowercase() }
        )
        if (query.isEmpty()) sorted
        else sorted.filter { it.name.contains(query, ignoreCase = true) }
    }

    val hasAnyParentFolder = remember(forest) { forest.any { it.children.isNotEmpty() } }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 8.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("目录与范围", style = MaterialTheme.typography.titleMedium)
            Row {
                IconButton(
                    onClick = {
                        createParentId = null
                        newFolderName = ""
                        showCreateFolder = true
                    }
                ) {
                    Icon(Icons.Rounded.CreateNewFolder, contentDescription = "新建文件夹")
                }
                IconButton(onClick = onOpenSettings) {
                    Icon(Icons.Rounded.Settings, contentDescription = "设置与同步")
                }
            }
        }

        // Quick Filter Input
        OutlinedTextField(
            value = quickFilter,
            onValueChange = { quickFilter = it },
            placeholder = { Text("快筛文件夹、智能目录或标签…") },
            leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null, modifier = Modifier.size(18.dp)) },
            trailingIcon = {
                if (quickFilter.isNotEmpty()) {
                    IconButton(onClick = { quickFilter = "" }) {
                        Icon(Icons.Rounded.Clear, contentDescription = "清空快筛", modifier = Modifier.size(18.dp))
                    }
                }
            },
            singleLine = true,
            shape = CircleShape,
            modifier = Modifier.fillMaxWidth()
        )

        // 2-Column Quick Scope Tiles (high-contrast elevated surface in Dark & Light modes)
        val quickScopes = listOf(
            Triple("全部素材", "library", LibraryScope.AllItems),
            Triple(if (state.inboxCount > 0) "收件箱 ${state.inboxCount}" else "收件箱", "inbox", LibraryScope.Inbox),
            Triple("最近浏览", "recent", LibraryScope.Recent),
            Triple("未打标签", "untagged", LibraryScope.Untagged),
            Triple("回收站", "trash", LibraryScope.Trash)
        )
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            quickScopes.chunked(2).forEach { pair ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    pair.forEach { (label, iconName, targetScope) ->
                        val active = state.scope == targetScope
                        Surface(
                            onClick = { onSelectScope(targetScope) },
                            shape = RoundedCornerShape(16.dp),
                            color = if (active) {
                                MaterialTheme.colorScheme.primaryContainer
                            } else {
                                cardSurface
                            },
                            modifier = Modifier.weight(1f)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 11.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                CharkleDuotoneIcon(
                                    name = iconName,
                                    contentDescription = label,
                                    active = active,
                                    modifier = Modifier.size(19.dp)
                                )
                                Text(
                                    text = label,
                                    style = MaterialTheme.typography.labelLarge,
                                    color = if (active) {
                                        MaterialTheme.colorScheme.onPrimaryContainer
                                    } else {
                                        MaterialTheme.colorScheme.onSurface
                                    },
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                    if (pair.size == 1) {
                        Surface(
                            onClick = onOpenPinterest,
                            shape = RoundedCornerShape(16.dp),
                            color = cardSurface,
                            modifier = Modifier.weight(1f)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 11.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Explore,
                                    contentDescription = "Pinterest 空间",
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(19.dp)
                                )
                                Text(
                                    text = "Pinterest",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                }
            }
        }

        // Collapsible Hierarchical Folders Tree
        SegmentedSection(title = "文件夹 (${state.folders.size})") {
            if (visibleFolderRows.isEmpty()) {
                SegmentedRowCard(
                    index = 0,
                    count = 1,
                    containerColor = cardSurface,
                    onClick = {
                        if (query.isEmpty()) {
                            createParentId = null
                            newFolderName = ""
                            showCreateFolder = true
                        } else {
                            quickFilter = ""
                        }
                    }
                ) {
                    Text(
                        text = if (query.isEmpty()) "点击新建第一个文件夹" else "没有匹配的文件夹 · 点击清空快筛",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
            } else {
                visibleFolderRows.forEachIndexed { idx, node ->
                    val folder = node.folder
                    val active = (state.scope as? LibraryScope.Folder)?.folderId.equals(folder.id, ignoreCase = true)
                    val expanded = query.isNotEmpty() || folder.id in expandedIds
                    val secondaryTint = if (active) {
                        MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.78f)
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    }
                    val indentDp = (minOf(node.depth, 5) * 14).dp

                    SegmentedRowCard(
                        index = idx,
                        count = visibleFolderRows.size,
                        containerColor = if (active) {
                            MaterialTheme.colorScheme.primaryContainer
                        } else {
                            cardSurface
                        },
                        onClick = { onSelectScope(LibraryScope.Folder(folder.id)) }
                    ) {
                        if (indentDp > 0.dp) {
                            Spacer(Modifier.width(indentDp))
                        }
                        if (node.children.isNotEmpty()) {
                            IconButton(
                                onClick = {
                                    expandedIds = if (folder.id in expandedIds) {
                                        expandedIds - folder.id
                                    } else {
                                        expandedIds + folder.id
                                    }
                                },
                                modifier = Modifier.size(26.dp)
                            ) {
                                Icon(
                                    imageVector = if (expanded) Icons.Rounded.KeyboardArrowDown else Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                                    contentDescription = if (expanded) "收起子文件夹" else "展开子文件夹",
                                    tint = secondaryTint,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        } else if (hasAnyParentFolder) {
                            Spacer(Modifier.width(26.dp))
                        } else {
                            Spacer(Modifier.width(2.dp))
                        }

                        CharkleDuotoneIcon(
                            name = "folder",
                            contentDescription = folder.name,
                            active = active,
                            customHex = folder.colorHex,
                            modifier = Modifier.size(20.dp)
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            text = folder.name,
                            style = MaterialTheme.typography.bodyMedium,
                            color = if (active) {
                                MaterialTheme.colorScheme.onPrimaryContainer
                            } else {
                                MaterialTheme.colorScheme.onSurface
                            },
                            modifier = Modifier.weight(1f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = folder.assetCount.toString(),
                            style = MaterialTheme.typography.labelMedium,
                            color = secondaryTint
                        )
                        Spacer(Modifier.width(4.dp))
                        IconButton(
                            onClick = { editingFolder = folder },
                            modifier = Modifier.size(28.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.MoreVert,
                                contentDescription = "管理文件夹",
                                tint = secondaryTint,
                                modifier = Modifier.size(17.dp)
                            )
                        }
                    }
                }
            }
        }

        // Smart Folders (interactive filter scope backed by SmartFolderRule)
        if (filteredSmartFolders.isNotEmpty()) {
            SegmentedSection(title = "智能文件夹 (${filteredSmartFolders.size})") {
                filteredSmartFolders.forEachIndexed { idx, sf ->
                    val active = (state.scope as? LibraryScope.SmartFolder)?.smartFolderId
                        .equals(sf.id, ignoreCase = true)
                    val ruleSummary = remember(sf.rule) { summarizeSmartFolderRule(sf.rule) }
                    val subtitleColor = if (active) {
                        MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.78f)
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    }
                    SegmentedRowCard(
                        index = idx,
                        count = filteredSmartFolders.size,
                        containerColor = if (active) {
                            MaterialTheme.colorScheme.primaryContainer
                        } else {
                            cardSurface
                        },
                        onClick = { onSelectScope(LibraryScope.SmartFolder(sf.id)) }
                    ) {
                        CharkleDuotoneIcon(
                            name = "smart-folder",
                            contentDescription = sf.name,
                            active = active,
                            customHex = sf.colorHex,
                            modifier = Modifier.size(19.dp)
                        )
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = sf.name,
                                style = MaterialTheme.typography.bodyMedium,
                                color = if (active) {
                                    MaterialTheme.colorScheme.onPrimaryContainer
                                } else {
                                    MaterialTheme.colorScheme.onSurface
                                },
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (ruleSummary != null) {
                                Text(
                                    text = ruleSummary,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = subtitleColor,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                }
            }
        }

        // Popular Tags Cloud (with active tag scope highlighting)
        val filteredTags = remember(state.tagCounts, query) {
            if (query.isEmpty()) state.tagCounts.take(20)
            else state.tagCounts.filter { it.tag.contains(query, ignoreCase = true) }.take(20)
        }
        if (filteredTags.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "常用标签",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 12.dp)
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    filteredTags.forEach { tc ->
                        val tagActive = (state.scope as? LibraryScope.Tag)?.tag.equals(tc.tag, ignoreCase = true)
                        ExpressivePillToggleChip(
                            label = "#${tc.tag} · ${tc.count}",
                            selected = tagActive,
                            unselectedContainerColor = cardSurface,
                            onClick = { onSelectScope(LibraryScope.Tag(tc.tag)) }
                        )
                    }
                }
            }
        }
    }

    if (showCreateFolder) {
        val parentFolder = createParentId?.let { pid ->
            state.folders.firstOrNull { it.id.equals(pid, ignoreCase = true) }
        }
        val canCreate = newFolderName.trim().isNotEmpty()
        fun submitCreate() {
            val trimmed = newFolderName.trim()
            if (trimmed.isEmpty()) return
            val pid = createParentId
            store.createFolder(trimmed, parentId = pid)
            if (pid != null) {
                expandedIds = expandedIds + pid
            }
            newFolderName = ""
            showCreateFolder = false
        }

        AlertDialog(
            onDismissRequest = {
                showCreateFolder = false
                newFolderName = ""
            },
            title = { Text(if (parentFolder == null) "新建文件夹" else "新建子文件夹") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (parentFolder != null) {
                        Text(
                            text = "将在「${parentFolder.name}」下创建子文件夹",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    OutlinedTextField(
                        value = newFolderName,
                        onValueChange = { newFolderName = it },
                        placeholder = { Text("例如：色彩参考、构图灵感") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { submitCreate() }),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = canCreate,
                    onClick = { submitCreate() }
                ) { Text("创建") }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        showCreateFolder = false
                        newFolderName = ""
                    }
                ) { Text("取消") }
            }
        )
    }

    editingFolder?.let { target ->
        var renameDraft by remember(target.id) { mutableStateOf(target.name) }
        val trimmedRename = renameDraft.trim()
        val canSave = trimmedRename.isNotEmpty()

        AlertDialog(
            onDismissRequest = { editingFolder = null },
            title = { Text("管理文件夹") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    OutlinedTextField(
                        value = renameDraft,
                        onValueChange = { renameDraft = it },
                        label = { Text("文件夹名称") },
                        isError = renameDraft.isBlank(),
                        supportingText = if (renameDraft.isBlank()) {
                            { Text("文件夹名称不能为空") }
                        } else {
                            null
                        },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )

                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                "文件夹色标（8 色）",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            if (target.colorHex != null) {
                                Text(
                                    text = "恢复默认",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(8.dp))
                                        .clickable {
                                            store.updateFolderColor(target.id, null)
                                            editingFolder = target.copy(colorHex = null)
                                        }
                                        .padding(horizontal = 6.dp, vertical = 2.dp)
                                )
                            }
                        }
                        // 2x4 touch-friendly palette grid (no cramping on narrow screens)
                        CharklePaletteTokens.folderPalette.chunked(4).forEach { rowHexes ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceEvenly
                            ) {
                                rowHexes.forEach { hex ->
                                    val c = parseHexColor(hex) ?: MaterialTheme.colorScheme.primary
                                    val isSelected = target.colorHex.equals(hex, ignoreCase = true)
                                    Box(
                                        contentAlignment = Alignment.Center,
                                        modifier = Modifier
                                            .size(36.dp)
                                            .clip(CircleShape)
                                            .background(c)
                                            .border(
                                                width = if (isSelected) 2.dp else 0.75.dp,
                                                color = if (isSelected) {
                                                    MaterialTheme.colorScheme.onSurface
                                                } else {
                                                    MaterialTheme.colorScheme.outlineVariant
                                                },
                                                shape = CircleShape
                                            )
                                            .clickable {
                                                val nextHex = if (isSelected) null else hex
                                                store.updateFolderColor(target.id, nextHex)
                                                editingFolder = target.copy(colorHex = nextHex)
                                            }
                                    ) {
                                        if (isSelected) {
                                            Icon(
                                                imageVector = Icons.Rounded.Check,
                                                contentDescription = "已选色标",
                                                tint = if (c.luminance() > 0.55f) Color(0xFF18191C) else Color.White,
                                                modifier = Modifier.size(18.dp)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        FilledTonalButton(
                            onClick = {
                                createParentId = target.id
                                newFolderName = ""
                                editingFolder = null
                                showCreateFolder = true
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Rounded.CreateNewFolder, contentDescription = null, modifier = Modifier.size(17.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("在此下新建子文件夹")
                        }
                        OutlinedButton(
                            onClick = {
                                editingFolder = null
                                deletingFolder = target
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(
                                Icons.Rounded.DeleteOutline,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(17.dp)
                            )
                            Spacer(Modifier.width(6.dp))
                            Text("删除文件夹…", color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = canSave,
                    onClick = {
                        if (trimmedRename.isNotEmpty() && trimmedRename != target.name) {
                            store.renameFolder(target.id, trimmedRename)
                        }
                        editingFolder = null
                    }
                ) { Text("保存") }
            },
            dismissButton = {
                TextButton(onClick = { editingFolder = null }) { Text("关闭") }
            }
        )
    }

    // Two-option Delete Folder Confirmation (Keep assets in Inbox vs Trash folder + assets)
    deletingFolder?.let { target ->
        val descendantCount = nodeById[target.id.uppercase()]?.let { countDescendants(it) } ?: 0
        val detailMessage = buildString {
            append("确定要删除文件夹「${target.name}」吗？")
            if (descendantCount > 0) {
                append("（含 $descendantCount 个子文件夹）")
            }
            append("\n\n请选择其中素材的处理方式：")
            if (target.assetCount > 0) {
                append("当前包含约 ${target.assetCount} 项素材。")
            }
        }

        AlertDialog(
            onDismissRequest = { deletingFolder = null },
            title = { Text("删除文件夹") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        text = detailMessage,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    FilledTonalButton(
                        onClick = {
                            store.deleteFolder(target.id, trashContents = false)
                            deletingFolder = null
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("保留素材（移入收件箱）")
                    }
                    OutlinedButton(
                        onClick = {
                            store.deleteFolder(target.id, trashContents = true)
                            deletingFolder = null
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(
                            Icons.Rounded.DeleteOutline,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(17.dp)
                        )
                        Spacer(Modifier.width(6.dp))
                        Text("连同素材移入回收站", color = MaterialTheme.colorScheme.error)
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { deletingFolder = null }) { Text("取消") }
            }
        )
    }
}

private fun summarizeSmartFolderRule(rule: SmartFolderRuleDto): String? {
    val parts = buildList {
        if (rule.tags.isNotEmpty()) {
            add(rule.tags.take(2).joinToString(" ") { "#$it" })
        }
        if (rule.minRating > 0) {
            add("${rule.minRating}★+")
        }
        if (rule.mediaKinds.isNotEmpty()) {
            val labels = rule.mediaKinds.take(2).map { kind ->
                when (kind) {
                    "image" -> "图片"
                    "animatedImage" -> "动图"
                    "video" -> "视频"
                    "webBookmark" -> "网页"
                    "document" -> "文档"
                    "designFile" -> "设计稿"
                    "audio" -> "音频"
                    "model3D" -> "3D"
                    else -> kind
                }
            }
            add(labels.joinToString("/"))
        }
        if (rule.colorHexes.isNotEmpty()) {
            add("主色 ${rule.colorHexes.first().uppercase()}")
        }
        if (rule.descriptionQuery.isNotBlank()) {
            add("「${rule.descriptionQuery.trim().take(12)}」")
        }
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

private fun containsQuery(nodes: List<FolderTreeNode>, query: String): Boolean {
    for (n in nodes) {
        if (n.folder.name.contains(query, ignoreCase = true) || containsQuery(n.children, query)) {
            return true
        }
    }
    return false
}

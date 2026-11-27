@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.capture

import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.Clear
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.charkle.android.designsystem.CharkleWavyProgress
import com.charkle.android.designsystem.ExpressivePillToggleChip
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState

@Composable
fun CaptureSheetContent(
    state: CharkleUiState,
    store: CharkleAppStore,
    onDone: () -> Unit
) {
    val context = LocalContext.current
    val isDark = LocalCharkleExtendedColors.current.isDark
    var targetFolderId by remember(state.activeFolderIdForCapture) {
        mutableStateOf(state.activeFolderIdForCapture)
    }
    var rawLink by remember { mutableStateOf("") }

    // Guard against stale selection if a folder was deleted while the sheet is open
    LaunchedEffect(state.folders) {
        val current = targetFolderId
        if (current != null && state.folders.none { it.id == current }) {
            targetFolderId = null
        }
    }

    val extractedLink = remember(rawLink) {
        SharedContentParser.extractLink(rawLink)
    }
    val hasLinkInputError = rawLink.isNotBlank() && extractedLink == null

    val photoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(20)
    ) { uris ->
        if (uris.isNotEmpty()) {
            store.ingestContentUris(uris, targetFolderId = targetFolderId, onDone = onDone)
        }
    }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) {
            store.ingestContentUris(uris, targetFolderId = targetFolderId, onDone = onDone)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text("快速采集素材", style = MaterialTheme.typography.headlineSmall)

        if (state.isIngesting) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = "正在解析并导入素材…",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary
                )
                CharkleWavyProgress(progress = 0.68f)
            }
        }

        // Destination folder Expressive pill strip
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("存入位置", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(7.dp),
                contentPadding = PaddingValues(vertical = 2.dp)
            ) {
                item {
                    ExpressivePillToggleChip(
                        label = "收件箱",
                        selected = targetFolderId == null,
                        onClick = { if (!state.isIngesting) targetFolderId = null }
                    )
                }
                items(state.folders, key = { it.id }) { folder ->
                    ExpressivePillToggleChip(
                        label = folder.name,
                        selected = targetFolderId == folder.id,
                        swatchColor = parseHexColor(folder.colorHex),
                        onClick = { if (!state.isIngesting) targetFolderId = folder.id }
                    )
                }
            }
        }

        val tileSurface = if (isDark) {
            MaterialTheme.colorScheme.surfaceContainerHigh
        } else {
            MaterialTheme.colorScheme.surfaceContainerLowest
        }

        // Multi-source expressive capture tiles with organic MaterialShapes icon medallions
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            CaptureTile(
                icon = Icons.Rounded.PhotoLibrary,
                badgeShape = MaterialShapes.Clover4Leaf.toShape(),
                title = "从相册导入",
                subtitle = "支持图/视频多选",
                containerColor = tileSurface,
                enabled = !state.isIngesting,
                modifier = Modifier.weight(1f),
                onClick = {
                    photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
                }
            )
            CaptureTile(
                icon = Icons.Rounded.FolderOpen,
                badgeShape = MaterialShapes.Cookie7Sided.toShape(),
                title = "从文件导入",
                subtitle = "图片、PDF、设计稿",
                containerColor = tileSurface,
                enabled = !state.isIngesting,
                modifier = Modifier.weight(1f),
                onClick = { filePicker.launch(arrayOf("*/*")) }
            )
        }

        CaptureTile(
            icon = Icons.Rounded.ContentPaste,
            badgeShape = MaterialShapes.SoftBurst.toShape(),
            title = "一键收藏剪贴板",
            subtitle = "自动识别小红书 / X / 网页链接与分享文案",
            containerColor = tileSurface,
            enabled = !state.isIngesting,
            modifier = Modifier.fillMaxWidth(),
            onClick = {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                val clip = cm?.primaryClip
                val text = if (clip != null && clip.itemCount > 0) {
                    clip.getItemAt(0)?.coerceToText(context)?.toString()?.trim()
                } else {
                    null
                }
                if (text.isNullOrBlank()) {
                    store.showToast("剪贴板暂无内容")
                    return@CaptureTile
                }
                val parsed = SharedContentParser.extractLink(text)
                if (parsed == null) {
                    rawLink = text
                    store.showToast("剪贴板内容中未识别到有效网页链接")
                } else {
                    rawLink = text
                    store.ingestWebUrl(
                        rawText = parsed.url,
                        targetFolderId = targetFolderId,
                        title = parsed.companionTitle,
                        notes = parsed.companionNotes,
                        onDone = onDone
                    )
                }
            }
        )

        // Link / share copy input with live URL extraction preview
        OutlinedTextField(
            value = rawLink,
            onValueChange = { rawLink = it },
            enabled = !state.isIngesting,
            label = { Text("网页或社媒分享链接") },
            placeholder = { Text("粘贴小红书、X、GitHub 或含链接的分享文案…") },
            leadingIcon = { Icon(Icons.Rounded.Link, contentDescription = null) },
            trailingIcon = {
                if (rawLink.isNotEmpty() && !state.isIngesting) {
                    IconButton(onClick = { rawLink = "" }) {
                        Icon(Icons.Rounded.Clear, contentDescription = "清空链接")
                    }
                }
            },
            isError = hasLinkInputError,
            supportingText = if (hasLinkInputError) {
                { Text("未检测到有效链接，请包含 http://、https:// 或 www. 网址") }
            } else {
                null
            },
            maxLines = 4,
            shape = RoundedCornerShape(18.dp),
            modifier = Modifier.fillMaxWidth()
        )

        if (extractedLink != null) {
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = MaterialTheme.colorScheme.secondaryContainer,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        imageVector = Icons.Rounded.CheckCircleOutline,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(18.dp)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.primaryContainer
                            ) {
                                Text(
                                    text = extractedLink.platformLabel ?: "网页链接",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                                )
                            }
                            Text(
                                text = extractedLink.host,
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSecondaryContainer,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = extractedLink.url,
                            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }

        Button(
            onClick = {
                val parsed = extractedLink ?: return@Button
                store.ingestWebUrl(
                    rawText = parsed.url,
                    targetFolderId = targetFolderId,
                    title = parsed.companionTitle,
                    notes = parsed.companionNotes,
                    onDone = onDone
                )
            },
            enabled = extractedLink != null && !state.isIngesting,
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier
                .fillMaxWidth()
                .height(54.dp)
        ) {
            Text(
                text = if (state.isIngesting) "正在解析并收藏…" else "解析并收藏链接",
                style = MaterialTheme.typography.titleSmall
            )
        }

        Spacer(Modifier.height(4.dp))
    }
}

@Composable
private fun CaptureTile(
    icon: ImageVector,
    badgeShape: Shape,
    title: String,
    subtitle: String,
    containerColor: Color,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(22.dp),
        color = containerColor,
        modifier = modifier.alpha(if (enabled) 1f else 0.55f)
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Surface(
                shape = badgeShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(42.dp)
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        imageVector = icon,
                        contentDescription = title,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

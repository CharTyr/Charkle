@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.capture

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.InsertDriveFile
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberBottomSheetState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.charkle.android.CharkleApplication
import com.charkle.android.designsystem.CharkleExpressiveTheme
import com.charkle.android.designsystem.CharkleWavyProgress
import com.charkle.android.designsystem.ExpressivePillToggleChip
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.parseHexColor
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private data class SharedMediaEntry(
    val uri: Uri,
    val mimeType: String?
) {
    val isImage: Boolean get() = mimeType?.startsWith("image/", ignoreCase = true) == true
    val isVideo: Boolean get() = mimeType?.startsWith("video/", ignoreCase = true) == true
}

private data class ParsedSharePayload(
    val mediaItems: List<SharedMediaEntry>,
    val rawText: String,
    val subject: String?,
    val extractedLink: ExtractedShareLink?
) {
    val hasMedia: Boolean get() = mediaItems.isNotEmpty()
    val hasLink: Boolean get() = extractedLink != null
    val canImport: Boolean get() = hasMedia || hasLink
}

private sealed interface ShareOutcome {
    data object Idle : ShareOutcome
    data class Success(val message: String) : ShareOutcome
    data class Error(val message: String) : ShareOutcome
}

/**
 * Translucent system Share Sheet receiver (`ACTION_SEND` / `ACTION_SEND_MULTIPLE`) for
 * zero-friction 1-tap saving from Xiaohongshu, X, browsers, Photos, and Files straight into Charkle.
 */
class ShareReceiveActivity : ComponentActivity() {

    private var payloadState by mutableStateOf<ParsedSharePayload?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val app = application as CharkleApplication
        val store = app.store
        store.bootstrap()

        payloadState = parseIncomingIntent(intent)

        setContent {
            val state by store.state.collectAsState()
            val payload = payloadState ?: ParsedSharePayload(emptyList(), "", null, null)
            val coroutineScope = rememberCoroutineScope()

            var selectedFolderId by remember { mutableStateOf<String?>(null) }
            // 0 = media when both media & link exist; 1 = link
            var importChoice by remember(payload) {
                mutableIntStateOf(if (payload.hasMedia) 0 else 1)
            }
            var outcome by remember(payload) { mutableStateOf<ShareOutcome>(ShareOutcome.Idle) }

            // Guard against stale folder selection if library reloads
            LaunchedEffect(state.folders) {
                val cur = selectedFolderId
                if (cur != null && state.folders.none { it.id == cur }) {
                    selectedFolderId = null
                }
            }

            CharkleExpressiveTheme(
                appearanceMode = state.appearanceMode,
                followSystemAccentOnControls = state.followSystemAccentOnControls
            ) {
                val extended = LocalCharkleExtendedColors.current
                val sheetState = rememberBottomSheetState(
                    initialValue = SheetValue.Hidden,
                    enabledValues = setOf(SheetValue.Hidden, SheetValue.Expanded),
                    confirmValueChange = { target ->
                        !(target == SheetValue.Hidden && state.isIngesting)
                    }
                )

                fun closeGracefully() {
                    coroutineScope.launch {
                        runCatching { sheetState.hide() }
                        finish()
                    }
                }

                // Auto-dismiss smoothly after showing brief confirmation banner
                LaunchedEffect(outcome) {
                    if (outcome is ShareOutcome.Success) {
                        delay(700)
                        closeGracefully()
                    }
                }

                val targetFolderName = remember(selectedFolderId, state.folders) {
                    if (selectedFolderId == null) {
                        "收件箱"
                    } else {
                        state.folders.firstOrNull { it.id == selectedFolderId }?.name ?: "目标文件夹"
                    }
                }

                val importMediaSelected = payload.hasMedia && (!payload.hasLink || importChoice == 0)

                ModalBottomSheet(
                    sheetState = sheetState,
                    onDismissRequest = {
                        if (!state.isIngesting) finish()
                    },
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .navigationBarsPadding()
                            .padding(horizontal = 20.dp)
                            .padding(bottom = 24.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        Text("收藏到 Charkle", style = MaterialTheme.typography.titleMedium)

                        // Media preview strip + summary
                        if (payload.hasMedia && importMediaSelected) {
                            Text(
                                text = buildMediaSummary(payload.mediaItems),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            val previewItems = payload.mediaItems.take(6)
                            val overflow = (payload.mediaItems.size - previewItems.size).coerceAtLeast(0)
                            LazyRow(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                contentPadding = PaddingValues(vertical = 2.dp)
                            ) {
                                items(previewItems, key = { it.uri.toString() }) { entry ->
                                    Box(
                                        modifier = Modifier
                                            .size(64.dp)
                                            .clip(RoundedCornerShape(12.dp))
                                            .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        if (entry.isImage || entry.isVideo) {
                                            AsyncImage(
                                                model = entry.uri,
                                                contentDescription = null,
                                                contentScale = ContentScale.Crop,
                                                modifier = Modifier.fillMaxSize()
                                            )
                                        } else {
                                            Icon(
                                                imageVector = Icons.AutoMirrored.Rounded.InsertDriveFile,
                                                contentDescription = null,
                                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                                modifier = Modifier.size(24.dp)
                                            )
                                        }
                                        if (entry.isVideo) {
                                            Box(
                                                modifier = Modifier
                                                    .size(24.dp)
                                                    .clip(CircleShape)
                                                    .background(Color.Black.copy(alpha = 0.58f)),
                                                contentAlignment = Alignment.Center
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Rounded.PlayArrow,
                                                    contentDescription = "视频",
                                                    tint = Color.White,
                                                    modifier = Modifier.size(16.dp)
                                                )
                                            }
                                        }
                                    }
                                }
                                if (overflow > 0) {
                                    item {
                                        Box(
                                            modifier = Modifier
                                                .size(64.dp)
                                                .clip(RoundedCornerShape(12.dp))
                                                .background(MaterialTheme.colorScheme.secondaryContainer),
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Text(
                                                text = "+$overflow",
                                                style = MaterialTheme.typography.titleSmall,
                                                color = MaterialTheme.colorScheme.onSecondaryContainer
                                            )
                                        }
                                    }
                                }
                            }
                        } else if (payload.extractedLink != null) {
                            val link = payload.extractedLink
                            Surface(
                                shape = RoundedCornerShape(14.dp),
                                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Link,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(20.dp)
                                    )
                                    Column(
                                        modifier = Modifier.weight(1f),
                                        verticalArrangement = Arrangement.spacedBy(3.dp)
                                    ) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                                        ) {
                                            Surface(
                                                shape = CircleShape,
                                                color = MaterialTheme.colorScheme.primaryContainer
                                            ) {
                                                Text(
                                                    text = link.platformLabel ?: "网页链接",
                                                    style = MaterialTheme.typography.labelSmall,
                                                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                                                    modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp)
                                                )
                                            }
                                            Text(
                                                text = link.host,
                                                style = MaterialTheme.typography.labelMedium,
                                                color = MaterialTheme.colorScheme.onSurface,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                        Text(
                                            text = link.url,
                                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }
                            }
                        } else {
                            Surface(
                                shape = RoundedCornerShape(14.dp),
                                color = MaterialTheme.colorScheme.errorContainer,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.ErrorOutline,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onErrorContainer,
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Text(
                                        text = if (payload.rawText.isNotBlank()) {
                                            "分享文案中未检测到有效网页链接（需包含 http://、https:// 或 www.）"
                                        } else {
                                            "未检测到可导入的媒体文件或网页链接"
                                        },
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onErrorContainer
                                    )
                                }
                            }
                        }

                        // When a share payload contains BOTH media and a URL, allow switching cleanly
                        if (payload.hasMedia && payload.hasLink) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                ExpressivePillToggleChip(
                                    label = "导入媒体 (${payload.mediaItems.size})",
                                    selected = importChoice == 0,
                                    onClick = { if (!state.isIngesting) importChoice = 0 }
                                )
                                ExpressivePillToggleChip(
                                    label = "仅收藏链接",
                                    selected = importChoice == 1,
                                    onClick = { if (!state.isIngesting) importChoice = 1 }
                                )
                            }
                        }

                        // Live progress / outcome feedback banners
                        if (state.isIngesting) {
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(
                                    text = "正在导入并解析内容…",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.primary
                                )
                                CharkleWavyProgress(progress = 0.72f)
                            }
                        } else {
                            when (val current = outcome) {
                                is ShareOutcome.Success -> {
                                    Surface(
                                        shape = RoundedCornerShape(14.dp),
                                        color = MaterialTheme.colorScheme.primaryContainer,
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.CheckCircle,
                                                contentDescription = null,
                                                tint = extended.positive,
                                                modifier = Modifier.size(20.dp)
                                            )
                                            Text(
                                                text = current.message,
                                                style = MaterialTheme.typography.bodyMedium,
                                                color = MaterialTheme.colorScheme.onPrimaryContainer
                                            )
                                        }
                                    }
                                }
                                is ShareOutcome.Error -> {
                                    Surface(
                                        shape = RoundedCornerShape(14.dp),
                                        color = MaterialTheme.colorScheme.errorContainer,
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.ErrorOutline,
                                                contentDescription = null,
                                                tint = MaterialTheme.colorScheme.onErrorContainer,
                                                modifier = Modifier.size(18.dp)
                                            )
                                            Text(
                                                text = current.message,
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onErrorContainer
                                            )
                                        }
                                    }
                                }
                                ShareOutcome.Idle -> Unit
                            }
                        }

                        // Target folder picker
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                text = "存入位置",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            LazyRow(
                                horizontalArrangement = Arrangement.spacedBy(7.dp),
                                contentPadding = PaddingValues(vertical = 2.dp)
                            ) {
                                item {
                                    ExpressivePillToggleChip(
                                        label = "收件箱",
                                        selected = selectedFolderId == null,
                                        onClick = { if (!state.isIngesting) selectedFolderId = null }
                                    )
                                }
                                items(state.folders, key = { it.id }) { folder ->
                                    ExpressivePillToggleChip(
                                        label = folder.name,
                                        selected = selectedFolderId == folder.id,
                                        swatchColor = parseHexColor(folder.colorHex),
                                        onClick = { if (!state.isIngesting) selectedFolderId = folder.id }
                                    )
                                }
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            TextButton(
                                enabled = !state.isIngesting && outcome !is ShareOutcome.Success,
                                onClick = { closeGracefully() },
                                modifier = Modifier.weight(1f)
                            ) {
                                Text("取消")
                            }
                            Button(
                                enabled = !state.isIngesting && outcome !is ShareOutcome.Success && payload.canImport,
                                onClick = {
                                    outcome = ShareOutcome.Idle
                                    if (importMediaSelected) {
                                        val uris = payload.mediaItems.map { it.uri }
                                        store.ingestContentUris(
                                            uris = uris,
                                            targetFolderId = selectedFolderId,
                                            onError = { errMsg ->
                                                outcome = ShareOutcome.Error(errMsg)
                                            },
                                            onDone = {
                                                outcome = ShareOutcome.Success("已存入「$targetFolderName」")
                                            }
                                        )
                                    } else {
                                        val link = payload.extractedLink ?: return@Button
                                        store.ingestWebUrl(
                                            rawText = link.url,
                                            targetFolderId = selectedFolderId,
                                            title = link.companionTitle,
                                            notes = link.companionNotes,
                                            onError = { errMsg ->
                                                outcome = ShareOutcome.Error(errMsg)
                                            },
                                            onDone = {
                                                outcome = ShareOutcome.Success("已收藏到「$targetFolderName」")
                                            }
                                        )
                                    }
                                },
                                modifier = Modifier.weight(2f)
                            ) {
                                Text(
                                    when {
                                        state.isIngesting -> "正在存入…"
                                        outcome is ShareOutcome.Success -> "已存入"
                                        outcome is ShareOutcome.Error -> "重试存入"
                                        else -> "存入素材库"
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        payloadState = parseIncomingIntent(intent)
    }

    private fun parseIncomingIntent(intent: Intent?): ParsedSharePayload {
        val uris = extractSharedUris(intent)
        val mediaItems = uris.map { uri ->
            val resolvedMime = runCatching { contentResolver.getType(uri) }.getOrNull()
                ?: intent?.type?.takeUnless { it == "*/*" }
            SharedMediaEntry(uri = uri, mimeType = resolvedMime)
        }

        val extraText = intent?.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        val clipText = if (extraText.isEmpty()) {
            val clip = intent?.clipData
            if (clip != null && clip.itemCount > 0) {
                clip.getItemAt(0)?.text?.toString()?.trim().orEmpty()
            } else {
                ""
            }
        } else {
            ""
        }
        val rawText = extraText.ifEmpty { clipText }
        val subject = intent?.getStringExtra(Intent.EXTRA_SUBJECT)?.trim()?.takeIf { it.isNotEmpty() }
        val extractedLink = SharedContentParser.extractLink(rawText = rawText, subject = subject)

        return ParsedSharePayload(
            mediaItems = mediaItems,
            rawText = rawText,
            subject = subject,
            extractedLink = extractedLink
        )
    }

    @Suppress("DEPRECATION")
    private fun extractSharedUris(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val unique = LinkedHashSet<Uri>()

        when (intent.action) {
            Intent.ACTION_SEND -> {
                val single = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (single != null) unique.add(single)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val multiple = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                } else {
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
                }
                unique.addAll(multiple)
            }
        }

        // Fallback & complement: many Android apps deliver shared media URIs via ClipData
        val clip = intent.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i)?.uri?.let { unique.add(it) }
            }
        }

        // Last-resort single content/file URI on intent.data
        if (unique.isEmpty()) {
            intent.data?.takeIf { it.scheme == "content" || it.scheme == "file" }?.let { unique.add(it) }
        }

        return unique.toList()
    }

    private fun buildMediaSummary(items: List<SharedMediaEntry>): String {
        val imageCount = items.count { it.isImage }
        val videoCount = items.count { it.isVideo }
        val otherCount = (items.size - imageCount - videoCount).coerceAtLeast(0)
        val parts = buildList {
            if (imageCount > 0) add("$imageCount 张图片")
            if (videoCount > 0) add("$videoCount 个视频")
            if (otherCount > 0) add("$otherCount 个文件")
        }
        return if (parts.isEmpty()) {
            "已接收 ${items.size} 个媒体文件"
        } else {
            "已接收 ${parts.joinToString(" · ")}"
        }
    }
}

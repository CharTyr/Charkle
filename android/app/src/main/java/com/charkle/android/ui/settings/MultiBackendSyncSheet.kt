@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.settings

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Login
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.CloudDone
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedSecureTextField
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.charkle.android.core.SyncBackendProfileDto
import com.charkle.android.designsystem.CharkleWavyProgress
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.SegmentedRowCard
import com.charkle.android.designsystem.SegmentedSection
import com.charkle.android.designsystem.connectedHorizontalButtonShape
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URI
import java.util.UUID

private val SYNC_INTERVAL_PRESETS = listOf(
    0 to "手动",
    15 to "15分",
    30 to "30分",
    60 to "1小时"
)

/**
 * Full Multi-Backend Cloud Sync Hub:
 * - Simultaneous Google Drive (browser OAuth + Shared Folder), WebDAV, and Local/Syncthing backends
 * - Live progress, per-backend connection testing with inline results, and background scheduling
 */
@Composable
fun MultiBackendSyncContent(
    state: CharkleUiState,
    store: CharkleAppStore,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val extended = LocalCharkleExtendedColors.current

    var editingProfile by remember { mutableStateOf<SyncBackendProfileDto?>(null) }
    var isCreatingNew by remember { mutableStateOf(false) }
    var oauthClientIdDraft by remember { mutableStateOf("") }
    var oauthClientIdError by remember { mutableStateOf<String?>(null) }
    var showGoogleSignOutConfirm by remember { mutableStateOf(false) }

    val jsonImporter = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri != null) {
            store.importGoogleOAuthClientJson(uri)
        }
    }

    val backends = state.syncConfig.backends
    val enabledCount = backends.count { it.isEnabled }
    val hasGoogleBackend = backends.any { it.mode == "directAPIWithGDirect" || it.mode == "gdirectMount" }

    val googleAccount = remember(state.syncStatus) {
        state.syncStatus.backendStatuses
            .firstOrNull { it.mode != "webDAV" && it.mode != "localOnly" && !it.account?.email.isNullOrBlank() }
            ?.account
            ?: state.syncStatus.account?.takeIf {
                it.source != "WebDAV" && it.source != "本地文件夹" && it.email.isNotBlank()
            }
    }

    val topLevelError = state.syncStatus.lastError

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "返回设置")
            }
            Text(
                text = "多后端双向同步",
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Button(
                onClick = { store.syncNow() },
                enabled = !state.isSyncing && enabledCount > 0
            ) {
                Icon(Icons.Rounded.Sync, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(if (state.isSyncing) "同步中" else "立即同步")
            }
        }

        // 1. Live Sync Status Hero + Separate Error Banner
        SegmentedSection(title = "连接状态") {
            SegmentedRowCard(index = 0, count = 1) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Icon(
                            imageVector = when {
                                !topLevelError.isNullOrBlank() -> Icons.Rounded.ErrorOutline
                                enabledCount > 0 -> Icons.Rounded.CloudDone
                                else -> Icons.Rounded.CloudOff
                            },
                            contentDescription = null,
                            tint = when {
                                !topLevelError.isNullOrBlank() -> MaterialTheme.colorScheme.error
                                enabledCount > 0 -> extended.positive
                                else -> extended.warning
                            }
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = when {
                                    enabledCount > 0 && state.syncStatus.pendingOpCount > 0 ->
                                        "已启用 $enabledCount 个同步后端 · 待同步 ${state.syncStatus.pendingOpCount} 项"
                                    enabledCount > 0 ->
                                        "已启用 $enabledCount 个同步后端"
                                    else ->
                                        "纯本地离线运行"
                                },
                                style = MaterialTheme.typography.titleSmall
                            )
                            Text(
                                text = state.syncStatus.currentDetail
                                    ?: "与 Mac / Windows / iOS 共用同一套 /.charkle/ 无损双向同步协议",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }

                    if (!topLevelError.isNullOrBlank()) {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = MaterialTheme.colorScheme.errorContainer,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 9.dp),
                                verticalAlignment = Alignment.Top,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.ErrorOutline,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onErrorContainer,
                                    modifier = Modifier.size(16.dp)
                                )
                                Text(
                                    text = topLevelError,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onErrorContainer
                                )
                            }
                        }
                    }

                    if (state.isSyncing || state.syncStatus.isSyncing) {
                        CharkleWavyProgress(
                            progress = (state.syncStatus.progressFraction ?: 0.45).toFloat()
                        )
                    }
                }
            }
        }

        // 2. Simultaneous Backends List + Adaptive Add Tiles
        SegmentedSection(title = "已配置的同步后端（可同时启用多个）") {
            if (backends.isEmpty()) {
                SegmentedRowCard(index = 0, count = 1) {
                    Text(
                        "尚未添加同步后端，可点击下方添加 Google Drive、WebDAV 或本地同步目录。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                backends.forEachIndexed { idx, profile ->
                    val backendStatus = state.syncStatus.backendStatuses.firstOrNull {
                        it.backendId.equals(profile.id, ignoreCase = true)
                    }
                    val backendErr = backendStatus?.lastError?.takeIf { it.isNotBlank() }
                    val backendAcc = backendStatus?.account

                    SegmentedRowCard(
                        index = idx,
                        count = backends.size,
                        onClick = {
                            isCreatingNew = false
                            editingProfile = profile
                        }
                    ) {
                        Icon(
                            imageVector = when (profile.mode) {
                                "webDAV" -> Icons.Rounded.Dns
                                "localOnly" -> Icons.Rounded.Folder
                                else -> Icons.Rounded.CloudDone
                            },
                            contentDescription = null,
                            tint = if (backendErr != null) {
                                MaterialTheme.colorScheme.error
                            } else if (profile.isEnabled) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            },
                            modifier = Modifier.size(20.dp)
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            Text(
                                text = profile.name.ifBlank { backendModeLabel(profile.mode) },
                                style = MaterialTheme.typography.titleSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = when (profile.mode) {
                                    "webDAV" -> profile.webdavServerUrl.ifBlank { "点击填写 WebDAV 地址" }
                                    "localOnly" -> profile.localLibraryPath.ifBlank { "点击填写本地或 Syncthing 目录" }
                                    else -> if (profile.sharedFolderUrlOrId.isNotBlank()) "共享目录协作" else "根目录：${profile.rootFolderName}"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (backendErr != null) {
                                Text(
                                    text = backendErr,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.error,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis
                                )
                            } else if (backendAcc != null && (backendAcc.email.isNotBlank() || backendAcc.displayName.isNotBlank())) {
                                Text(
                                    text = "已连接：${backendAcc.email.ifBlank { backendAcc.displayName }}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = extended.positive,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                        Spacer(Modifier.width(8.dp))
                        Switch(
                            checked = profile.isEnabled,
                            onCheckedChange = { enabled ->
                                store.upsertSyncBackend(profile.copy(isEnabled = enabled))
                            }
                        )
                    }
                }
            }
        }

        // Responsive 3-column stacked connected add-backend buttons (zero truncation on 360dp)
        AddBackendConnectedRow(
            onAddGoogleDrive = {
                isCreatingNew = true
                editingProfile = SyncBackendProfileDto(
                    id = UUID.randomUUID().toString().uppercase(),
                    name = "Google Drive",
                    mode = "directAPIWithGDirect",
                    isEnabled = true,
                    isPrimary = backends.isEmpty()
                )
            },
            onAddWebDav = {
                isCreatingNew = true
                editingProfile = SyncBackendProfileDto(
                    id = UUID.randomUUID().toString().uppercase(),
                    name = "WebDAV 云盘",
                    mode = "webDAV",
                    isEnabled = true,
                    isPrimary = backends.isEmpty()
                )
            },
            onAddLocal = {
                isCreatingNew = true
                editingProfile = SyncBackendProfileDto(
                    id = UUID.randomUUID().toString().uppercase(),
                    name = "本地同步目录",
                    mode = "localOnly",
                    isEnabled = true,
                    isPrimary = backends.isEmpty()
                )
            }
        )

        // 3. Google OAuth Section (when a Google Drive backend exists)
        if (hasGoogleBackend) {
            SegmentedSection(title = "Google 账号与云盘授权") {
                SegmentedRowCard(index = 0, count = 2) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        if (googleAccount != null) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Icon(Icons.Rounded.Verified, contentDescription = null, tint = extended.positive)
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        googleAccount.displayName.ifBlank { "Google 账号" },
                                        style = MaterialTheme.typography.titleSmall,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        googleAccount.email,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                                OutlinedButton(onClick = { showGoogleSignOutConfirm = true }) {
                                    Icon(Icons.AutoMirrored.Rounded.Logout, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("退出")
                                }
                            }
                        } else {
                            Text(
                                text = if (state.hasGoogleOAuthClient) {
                                    "授权凭据已就绪，点击下方将拉起系统安全浏览器完成 Google 账号登录，授权后自动返回 Charkle。"
                                } else {
                                    "请先导入从 Google Cloud Console 下载的 client_secret.json，或在下方手动粘贴 OAuth Client ID（回调地址：charkle-android://oauth/callback）。"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Column(
                                modifier = Modifier.fillMaxWidth(),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Button(
                                    enabled = state.hasGoogleOAuthClient,
                                    onClick = {
                                        store.beginGoogleOAuthFlow { authUrl ->
                                            launchSafeCustomTab(context, authUrl) { errMsg ->
                                                store.showToast(errMsg)
                                            }
                                        }
                                    },
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Icon(Icons.AutoMirrored.Rounded.Login, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("使用 Google 账号登录")
                                }
                                FilledTonalButton(
                                    onClick = { jsonImporter.launch(arrayOf("application/json", "*/*")) },
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Icon(Icons.Rounded.Key, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text(if (state.hasGoogleOAuthClient) "重新导入凭据 JSON" else "导入凭据 JSON 文件")
                                }
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
                            value = oauthClientIdDraft,
                            onValueChange = {
                                oauthClientIdDraft = it
                                oauthClientIdError = null
                            },
                            label = { Text("手动填写 OAuth Client ID") },
                            placeholder = { Text("123456-xxxx.apps.googleusercontent.com") },
                            isError = oauthClientIdError != null,
                            supportingText = oauthClientIdError?.let { msg -> { Text(msg) } },
                            singleLine = true,
                            shape = RoundedCornerShape(14.dp),
                            modifier = Modifier.fillMaxWidth()
                        )
                        OutlinedButton(
                            enabled = oauthClientIdDraft.isNotBlank(),
                            onClick = {
                                val trimmed = oauthClientIdDraft.trim()
                                val validationErr = validateGoogleClientId(trimmed)
                                if (validationErr != null) {
                                    oauthClientIdError = validationErr
                                } else {
                                    store.saveGoogleClientId(trimmed)
                                    oauthClientIdDraft = ""
                                    oauthClientIdError = null
                                }
                            }
                        ) {
                            Text("保存 Client ID")
                        }
                    }
                }
            }
        }

        // 4. Background Sync & Bandwidth Options
        SegmentedSection(title = "后台自动同步与流量策略") {
            SegmentedRowCard(index = 0, count = 3) {
                val currentSec = state.syncConfig.autoSyncIntervalSeconds
                val matchesPreset = SYNC_INTERVAL_PRESETS.any { (mins, _) -> mins * 60 == currentSec }

                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("后台增量同步周期", style = MaterialTheme.typography.bodyMedium)
                    SyncIntervalSelectorRow(
                        currentSeconds = currentSec,
                        presets = SYNC_INTERVAL_PRESETS,
                        onSelectMinutes = { mins ->
                            store.updateBackgroundSyncIntervalMinutes(mins.toLong())
                        }
                    )
                    if (!matchesPreset && currentSec > 0) {
                        val currentMin = (currentSec / 60).coerceAtLeast(1)
                        Text(
                            text = "当前来自跨端同步配置（每 $currentMin 分钟）；Android 后台定时任务最小间隔为 15 分钟，可在上方重选。",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            SegmentedRowCard(index = 1, count = 3) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("优先同步缩略图", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "新设备几秒内先浏览全库，原图按需加载",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Switch(
                    checked = state.syncConfig.syncThumbnails,
                    onCheckedChange = { store.updateSyncFlags(syncThumbnails = it) }
                )
            }

            SegmentedRowCard(index = 2, count = 3) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("同步视觉特征向量", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "跨设备共享以图搜图与相似推荐索引",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Switch(
                    checked = state.syncConfig.syncEmbeddings,
                    onCheckedChange = { store.updateSyncFlags(syncEmbeddings = it) }
                )
            }
        }
    }

    // Backend Editor Dialog
    editingProfile?.let { initial ->
        BackendEditorDialog(
            initial = initial,
            isNew = isCreatingNew,
            store = store,
            onDismiss = { editingProfile = null },
            onSave = { updated, webdavPwd ->
                store.upsertSyncBackend(updated, webdavPassword = webdavPwd)
                editingProfile = null
            },
            onDelete = {
                store.removeSyncBackend(initial.id)
                editingProfile = null
            }
        )
    }

    if (showGoogleSignOutConfirm) {
        AlertDialog(
            onDismissRequest = { showGoogleSignOutConfirm = false },
            title = { Text("退出 Google 账号？") },
            text = { Text("退出后将暂停 Google Drive 云端同步，本地已缓存素材不会被删除。") },
            confirmButton = {
                TextButton(
                    onClick = {
                        showGoogleSignOutConfirm = false
                        store.signOutGoogle()
                    }
                ) { Text("退出账号", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showGoogleSignOutConfirm = false }) { Text("取消") }
            }
        )
    }
}

@Composable
private fun AddBackendConnectedRow(
    onAddGoogleDrive: () -> Unit,
    onAddWebDav: () -> Unit,
    onAddLocal: () -> Unit
) {
    val entries = listOf(
        Triple(Icons.Rounded.Add, "Google Drive", onAddGoogleDrive),
        Triple(Icons.Rounded.Dns, "WebDAV", onAddWebDav),
        Triple(Icons.Rounded.Folder, "本地目录", onAddLocal)
    )
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(2.5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        entries.forEachIndexed { index, (icon, label, action) ->
            val interactionSource = remember { MutableInteractionSource() }
            val pressed by interactionSource.collectIsPressedAsState()
            val shape = connectedHorizontalButtonShape(
                index = index,
                count = entries.size,
                isChecked = false,
                isPressed = pressed
            )
            Surface(
                shape = shape,
                color = MaterialTheme.colorScheme.secondaryContainer,
                contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                modifier = Modifier
                    .weight(1f)
                    .height(58.dp)
                    .clip(shape)
                    .clickable(
                        interactionSource = interactionSource,
                        indication = null,
                        onClick = action
                    )
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Icon(icon, contentDescription = "添加 $label", modifier = Modifier.size(19.dp))
                    Spacer(Modifier.height(3.dp))
                    Text(
                        text = label,
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

@Composable
private fun SyncIntervalSelectorRow(
    currentSeconds: Int,
    presets: List<Pair<Int, String>>,
    onSelectMinutes: (Int) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(2.5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        presets.forEachIndexed { index, (mins, label) ->
            val checked = currentSeconds == mins * 60
            val interactionSource = remember { MutableInteractionSource() }
            val pressed by interactionSource.collectIsPressedAsState()
            val shape = connectedHorizontalButtonShape(
                index = index,
                count = presets.size,
                isChecked = checked,
                isPressed = pressed
            )
            val bg by animateColorAsState(
                targetValue = if (checked) {
                    MaterialTheme.colorScheme.primary
                } else {
                    MaterialTheme.colorScheme.secondaryContainer
                },
                animationSpec = MaterialTheme.motionScheme.fastEffectsSpec(),
                label = "syncIntervalBg"
            )
            val fg by animateColorAsState(
                targetValue = if (checked) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.onSecondaryContainer
                },
                animationSpec = MaterialTheme.motionScheme.fastEffectsSpec(),
                label = "syncIntervalFg"
            )
            Surface(
                shape = shape,
                color = bg,
                contentColor = fg,
                modifier = Modifier
                    .weight(1f)
                    .height(38.dp)
                    .clip(shape)
                    .clickable(
                        interactionSource = interactionSource,
                        indication = null,
                        onClick = { onSelectMinutes(mins) }
                    )
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(
                        text = label,
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

private data class LocalDirCheck(
    val exists: Boolean,
    val isDirectory: Boolean,
    val canWrite: Boolean
)

@Composable
private fun BackendEditorDialog(
    initial: SyncBackendProfileDto,
    isNew: Boolean,
    store: CharkleAppStore,
    onDismiss: () -> Unit,
    onSave: (SyncBackendProfileDto, String?) -> Unit,
    onDelete: () -> Unit
) {
    val context = LocalContext.current
    val extended = LocalCharkleExtendedColors.current
    val coroutineScope = rememberCoroutineScope()

    var name by remember(initial.id) { mutableStateOf(initial.name) }
    var rootFolder by remember(initial.id) { mutableStateOf(initial.rootFolderName) }
    var sharedUrl by remember(initial.id) { mutableStateOf(initial.sharedFolderUrlOrId) }
    var webdavUrl by remember(initial.id) { mutableStateOf(initial.webdavServerUrl) }
    var webdavUser by remember(initial.id) { mutableStateOf(initial.webdavUsername) }
    val webdavPwdState = rememberTextFieldState()
    var webdavPath by remember(initial.id) { mutableStateOf(initial.webdavRemotePath) }
    var localPath by remember(initial.id) { mutableStateOf(initial.localLibraryPath) }

    var hasSavedPassword by remember(initial.id) { mutableStateOf(false) }
    var checkedSavedPassword by remember(initial.id) { mutableStateOf(isNew || initial.mode != "webDAV") }
    var localDirCheck by remember(initial.id) { mutableStateOf<LocalDirCheck?>(null) }

    var isTesting by remember(initial.id) { mutableStateOf(false) }
    var testSuccessMessage by remember(initial.id) { mutableStateOf<String?>(null) }
    var testErrorMessage by remember(initial.id) { mutableStateOf<String?>(null) }
    var confirmDelete by remember(initial.id) { mutableStateOf(false) }

    LaunchedEffect(initial.id, initial.mode, isNew) {
        if (!isNew && initial.mode == "webDAV") {
            hasSavedPassword = store.hasBackendWebDavPassword(initial.id)
            checkedSavedPassword = true
        }
    }

    LaunchedEffect(localPath, initial.mode) {
        if (initial.mode == "localOnly") {
            val trimmed = localPath.trim()
            if (trimmed.isEmpty()) {
                localDirCheck = null
            } else {
                localDirCheck = withContext(Dispatchers.IO) {
                    val f = File(trimmed)
                    LocalDirCheck(
                        exists = f.exists(),
                        isDirectory = f.isDirectory,
                        canWrite = f.exists() && f.canWrite()
                    )
                }
            }
        }
    }

    val directoryPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { treeUri ->
        if (treeUri != null) {
            val resolved = resolveTreeUriToFilePath(treeUri)
            if (resolved != null) {
                localPath = resolved
                testSuccessMessage = null
                testErrorMessage = null
            } else {
                testErrorMessage = "所选外部存储位置暂不支持直接路径映射，请手动输入路径或选择内置存储目录。"
            }
        }
    }

    val webdavUrlValidation = remember(webdavUrl, initial.mode) {
        if (initial.mode == "webDAV") validateWebDavUrl(webdavUrl) else null
    }
    val localPathError = remember(localPath, initial.mode) {
        if (initial.mode == "localOnly" && localPath.isBlank()) "请填写或选择本地同步目录路径" else null
    }
    val isFormValid = when (initial.mode) {
        "webDAV" -> webdavUrlValidation?.error == null
        "localOnly" -> localPath.isNotBlank()
        else -> rootFolder.isNotBlank() || sharedUrl.isNotBlank()
    }

    fun normalizedRemotePath(raw: String): String {
        val clean = raw.trim()
        if (clean.isEmpty()) return "/Charkle"
        return if (clean.startsWith("/")) clean else "/$clean"
    }

    fun currentDraft(): SyncBackendProfileDto = initial.copy(
        name = name.trim().ifBlank { backendModeLabel(initial.mode) },
        rootFolderName = rootFolder.trim().ifBlank { "Charkle" },
        sharedFolderUrlOrId = sharedUrl.trim(),
        webdavServerUrl = webdavUrl.trim(),
        webdavUsername = webdavUser.trim(),
        webdavRemotePath = normalizedRemotePath(webdavPath),
        localLibraryPath = localPath.trim()
    )

    fun clearTestBanner() {
        testSuccessMessage = null
        testErrorMessage = null
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (isNew) "添加${backendModeLabel(initial.mode)}" else "编辑同步后端") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("显示名称") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                when (initial.mode) {
                    "webDAV" -> {
                        val urlError = webdavUrlValidation?.error
                        val urlWarning = webdavUrlValidation?.warning
                        OutlinedTextField(
                            value = webdavUrl,
                            onValueChange = {
                                webdavUrl = it
                                clearTestBanner()
                            },
                            label = { Text("WebDAV 服务器地址") },
                            placeholder = { Text("https://dav.example.com/dav/") },
                            isError = webdavUrl.isNotBlank() && urlError != null,
                            supportingText = when {
                                webdavUrl.isNotBlank() && urlError != null -> ({ Text(urlError) })
                                urlWarning != null -> ({ Text(urlWarning, color = extended.warning) })
                                else -> null
                            },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                        OutlinedTextField(
                            value = webdavUser,
                            onValueChange = {
                                webdavUser = it
                                clearTestBanner()
                            },
                            label = { Text("用户名") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                        OutlinedSecureTextField(
                            state = webdavPwdState,
                            label = {
                                Text(if (hasSavedPassword) "应用密码（留空沿用已保存密码）" else "应用密码（加密保存）")
                            },
                            modifier = Modifier.fillMaxWidth()
                        )
                        if (checkedSavedPassword) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Icon(
                                    imageVector = if (hasSavedPassword) Icons.Rounded.Verified else Icons.Rounded.Info,
                                    contentDescription = null,
                                    tint = if (hasSavedPassword) extended.positive else MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(15.dp)
                                )
                                Text(
                                    text = if (hasSavedPassword) {
                                        "已加密保存应用密码，输入新密码可覆盖更新"
                                    } else {
                                        "尚未保存应用密码，请填写后保存或测试连接"
                                    },
                                    style = MaterialTheme.typography.labelSmall,
                                    color = if (hasSavedPassword) extended.positive else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                        OutlinedTextField(
                            value = webdavPath,
                            onValueChange = {
                                webdavPath = it
                                clearTestBanner()
                            },
                            label = { Text("远端目录路径") },
                            placeholder = { Text("/Charkle") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }

                    "localOnly" -> {
                        OutlinedTextField(
                            value = localPath,
                            onValueChange = {
                                localPath = it
                                clearTestBanner()
                            },
                            label = { Text("本地 / Syncthing 同步目录路径") },
                            placeholder = { Text("/storage/emulated/0/Charkle") },
                            isError = localPath.isNotBlank() && localDirCheck?.let { it.exists && !it.isDirectory } == true,
                            supportingText = {
                                val check = localDirCheck
                                when {
                                    localPath.isBlank() -> Text("可点击下方按钮选择目录或使用应用专属同步目录")
                                    check == null -> Unit
                                    check.exists && !check.isDirectory -> Text("该路径不是文件夹，请重新指定")
                                    check.exists && check.canWrite -> Text("目录存在且可读写", color = extended.positive)
                                    check.exists && !check.canWrite -> Text("目录存在但当前无写入权限，建议改用应用同步目录或检查权限", color = extended.warning)
                                    else -> Text("目录尚未创建，同步或测试时将尝试自动创建")
                                }
                            },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            modifier = Modifier.fillMaxWidth()
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            FilledTonalButton(
                                onClick = { directoryPicker.launch(null) },
                                modifier = Modifier.weight(1f)
                            ) {
                                Icon(Icons.Rounded.FolderOpen, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("选择目录", maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                            OutlinedButton(
                                onClick = {
                                    val appDir = context.getExternalFilesDir("CharkleSync")
                                        ?: File(context.filesDir, "CharkleSync")
                                    localPath = appDir.absolutePath
                                    clearTestBanner()
                                },
                                modifier = Modifier.weight(1f)
                            ) {
                                Text("应用目录", maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }

                    else -> {
                        OutlinedTextField(
                            value = rootFolder,
                            onValueChange = {
                                rootFolder = it
                                clearTestBanner()
                            },
                            label = { Text("云端根目录名称") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                        OutlinedTextField(
                            value = sharedUrl,
                            onValueChange = {
                                sharedUrl = it
                                clearTestBanner()
                            },
                            label = { Text("共享文件夹链接或 ID（可选）") },
                            placeholder = { Text("留空则同步至我的云端硬盘") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }

                // Inline test connection result banner (visible right inside AlertDialog!)
                if (testSuccessMessage != null) {
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.primaryContainer,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                Icons.Rounded.CheckCircleOutline,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.size(17.dp)
                            )
                            Text(
                                text = testSuccessMessage.orEmpty(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer
                            )
                        }
                    }
                } else if (testErrorMessage != null) {
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.errorContainer,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.Top,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                Icons.Rounded.ErrorOutline,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onErrorContainer,
                                modifier = Modifier.size(17.dp)
                            )
                            Text(
                                text = testErrorMessage.orEmpty(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onErrorContainer
                            )
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    OutlinedButton(
                        enabled = !isTesting && isFormValid,
                        onClick = {
                            val draft = currentDraft()
                            val pwd = webdavPwdState.text.toString().takeIf { it.isNotBlank() }
                            isTesting = true
                            testSuccessMessage = null
                            testErrorMessage = null
                            coroutineScope.launch {
                                runCatching {
                                    store.repository.testBackendConnection(draft, pwd)
                                }.onSuccess { info ->
                                    val label = info.displayName.ifBlank { info.email.ifBlank { info.source } }
                                    testSuccessMessage = "连接成功：$label"
                                }.onFailure { err ->
                                    testErrorMessage = "连接失败：${err.message ?: "请检查地址与凭据"}"
                                }
                                isTesting = false
                            }
                        }
                    ) {
                        if (isTesting) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(15.dp),
                                strokeWidth = 2.dp
                            )
                            Spacer(Modifier.width(6.dp))
                            Text("测试中…")
                        } else {
                            Text("测试连接")
                        }
                    }

                    if (!isNew) {
                        if (confirmDelete) {
                            TextButton(onClick = onDelete) {
                                Text("确认移除", color = MaterialTheme.colorScheme.error)
                            }
                        } else {
                            TextButton(onClick = { confirmDelete = true }) {
                                Icon(
                                    Icons.Rounded.DeleteOutline,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(16.dp)
                                )
                                Spacer(Modifier.width(4.dp))
                                Text("移除", color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            Button(
                enabled = isFormValid && !isTesting,
                onClick = {
                    val err = localPathError ?: webdavUrlValidation?.error
                    if (err != null) {
                        testErrorMessage = err
                    } else {
                        onSave(currentDraft(), webdavPwdState.text.toString().takeIf { it.isNotBlank() })
                    }
                }
            ) {
                Text("保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        }
    )
}

private data class UrlValidationResult(
    val error: String? = null,
    val warning: String? = null
)

private fun validateWebDavUrl(raw: String): UrlValidationResult {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return UrlValidationResult(error = "请输入 WebDAV 服务器地址")
    if (trimmed.any { it.isWhitespace() }) return UrlValidationResult(error = "地址不能包含空格")
    val lower = trimmed.lowercase()
    if (!lower.startsWith("https://") && !lower.startsWith("http://")) {
        return UrlValidationResult(error = "请以 https:// 或 http:// 开头")
    }
    val parsed = runCatching { URI(trimmed) }.getOrNull()
        ?: return UrlValidationResult(error = "地址格式无效，请检查拼写")
    val host = parsed.host?.lowercase()
    if (host.isNullOrBlank()) {
        return UrlValidationResult(error = "缺少有效的服务器域名或 IP")
    }
    val isLocalHost = host == "localhost" ||
        host.startsWith("127.") ||
        host.startsWith("192.168.") ||
        host.startsWith("10.") ||
        host.endsWith(".local")
    val warning = if (lower.startsWith("http://") && !isLocalHost) {
        "当前为非加密 HTTP 连接，公网环境建议改用 HTTPS"
    } else {
        null
    }
    return UrlValidationResult(error = null, warning = warning)
}

private fun validateGoogleClientId(trimmed: String): String? {
    if (trimmed.isEmpty()) return "请输入 OAuth Client ID"
    if (trimmed.any { it.isWhitespace() }) return "Client ID 不能包含空格或换行"
    if (!trimmed.endsWith(".apps.googleusercontent.com", ignoreCase = true)) {
        return "格式通常以 .apps.googleusercontent.com 结尾，请核对后重试"
    }
    if (trimmed.length < 35) return "Client ID 长度异常，请粘贴完整字符串"
    return null
}

private fun resolveTreeUriToFilePath(treeUri: Uri): String? {
    val docId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull() ?: return null
    val parts = docId.split(':', limit = 2)
    if (parts.isEmpty()) return null
    val volume = parts[0]
    val relative = parts.getOrNull(1).orEmpty().trimStart('/')
    if (volume.equals("primary", ignoreCase = true)) {
        val base = Environment.getExternalStorageDirectory().absolutePath
        return if (relative.isEmpty()) base else "$base/$relative"
    }
    return null
}

private fun backendModeLabel(mode: String): String = when (mode) {
    "webDAV" -> "WebDAV 云盘"
    "localOnly" -> "本地目录"
    else -> "Google Drive"
}

private fun launchSafeCustomTab(context: Context, url: String, onError: (String) -> Unit) {
    val uri = runCatching { url.toUri() }.getOrNull()
    if (uri == null) {
        onError("无效的授权链接")
        return
    }
    val customTabResult = runCatching {
        val intent = CustomTabsIntent.Builder()
            .setShowTitle(true)
            .build()
        intent.launchUrl(context, uri)
    }
    if (customTabResult.isSuccess) return

    val fallbackResult = runCatching {
        val viewIntent = Intent(Intent.ACTION_VIEW, uri).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(viewIntent)
    }
    if (fallbackResult.isFailure) {
        val reason = if (fallbackResult.exceptionOrNull() is ActivityNotFoundException) {
            "未检测到可用浏览器，无法打开 Google 授权页面"
        } else {
            "无法打开授权页面：${fallbackResult.exceptionOrNull()?.message.orEmpty()}"
        }
        onError(reason)
    }
}

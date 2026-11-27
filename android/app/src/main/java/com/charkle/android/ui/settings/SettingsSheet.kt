@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.ui.settings

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.BrightnessAuto
import androidx.compose.material.icons.rounded.CloudDone
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.LightMode
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.charkle.android.designsystem.CharkleAppearanceMode
import com.charkle.android.designsystem.CharkleConnectedButtonGroup
import com.charkle.android.designsystem.CharkleWavyProgress
import com.charkle.android.designsystem.ConnectedActionItem
import com.charkle.android.designsystem.LocalCharkleExtendedColors
import com.charkle.android.designsystem.SegmentedRowCard
import com.charkle.android.designsystem.SegmentedSection
import com.charkle.android.designsystem.connectedHorizontalButtonShape
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import java.util.Locale
import kotlin.math.roundToInt

private const val BYTES_PER_GB = 1024L * 1024L * 1024L
private val CACHE_BUDGET_PRESETS_GB = listOf(1, 2, 4, 8)

@Composable
fun SettingsSheetContent(
    state: CharkleUiState,
    store: CharkleAppStore,
    onDone: () -> Unit
) {
    var showSyncSubpage by remember { mutableStateOf(false) }
    var showEvictConfirm by remember { mutableStateOf(false) }

    BackHandler(enabled = showSyncSubpage) {
        showSyncSubpage = false
    }

    if (showSyncSubpage) {
        MultiBackendSyncContent(
            state = state,
            store = store,
            onBack = { showSyncSubpage = false }
        )
        return
    }

    val extended = LocalCharkleExtendedColors.current
    val enabledBackends = state.syncConfig.backends.count { it.isEnabled }
    val syncError = state.syncStatus.lastError
        ?: state.syncStatus.backendStatuses.firstOrNull { !it.lastError.isNullOrBlank() }?.lastError

    val totalUsedBytes = state.cacheStats.thumbnailBytes + state.cacheStats.originalCacheBytes
    val budgetBytes = state.cacheStats.budgetBytes.coerceAtLeast(BYTES_PER_GB)
    val budgetGbRounded = (budgetBytes.toDouble() / BYTES_PER_GB.toDouble()).roundToInt().coerceAtLeast(1)
    val usageFraction = (totalUsedBytes.toDouble() / budgetBytes.toDouble()).toFloat().coerceIn(0f, 1f)
    val reclaimableBytes = (state.cacheStats.originalCacheBytes - state.cacheStats.pinnedOfflineBytes)
        .coerceAtLeast(0L)

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
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("设置与多后端同步", style = MaterialTheme.typography.titleMedium)
            TextButton(onClick = onDone) { Text("完成") }
        }

        // 1. Cloud Sync Hub Entry + Quick Sync + Error Surfacing
        SegmentedSection(title = "云端同步（与 Mac / Windows / iOS 互通）") {
            SegmentedRowCard(
                index = 0,
                count = 2,
                onClick = { showSyncSubpage = true }
            ) {
                Icon(
                    imageVector = when {
                        syncError != null -> Icons.Rounded.ErrorOutline
                        enabledBackends > 0 -> Icons.Rounded.CloudDone
                        else -> Icons.Rounded.CloudOff
                    },
                    contentDescription = null,
                    tint = when {
                        syncError != null -> MaterialTheme.colorScheme.error
                        enabledBackends > 0 -> extended.positive
                        else -> extended.warning
                    },
                    modifier = Modifier.size(22.dp)
                )
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text("管理多后端同步", style = MaterialTheme.typography.titleSmall)
                    val subtitle = when {
                        syncError != null -> "同步出现异常 · 点击查看详情"
                        enabledBackends > 0 && state.syncStatus.pendingOpCount > 0 ->
                            "已启用 $enabledBackends 个后端 · 待同步 ${state.syncStatus.pendingOpCount} 项"
                        enabledBackends > 0 ->
                            "已启用 $enabledBackends 个同步后端 · 点击管理凭据与周期"
                        else ->
                            "点击配置 Google Drive / WebDAV / 本地同步目录"
                    }
                    Text(
                        text = subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (syncError != null) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Icon(
                    imageVector = Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            SegmentedRowCard(index = 1, count = 2) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = when {
                                state.isSyncing || state.syncStatus.isSyncing ->
                                    state.syncStatus.currentDetail ?: "正在执行双向同步…"
                                enabledBackends == 0 ->
                                    "尚未启用同步后端，请先添加并启用云盘或本地目录"
                                else ->
                                    state.syncStatus.currentDetail ?: "立即执行增量双向合并"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.weight(1f)
                        )
                        Button(
                            onClick = {
                                if (enabledBackends == 0) {
                                    showSyncSubpage = true
                                } else {
                                    store.syncNow()
                                }
                            },
                            enabled = !state.isSyncing
                        ) {
                            Icon(Icons.Rounded.Sync, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(
                                when {
                                    state.isSyncing -> "同步中"
                                    enabledBackends == 0 -> "去配置"
                                    else -> "立即同步"
                                }
                            )
                        }
                    }
                    if (!syncError.isNullOrBlank()) {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = MaterialTheme.colorScheme.errorContainer,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.ErrorOutline,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onErrorContainer,
                                    modifier = Modifier.size(16.dp)
                                )
                                Text(
                                    text = syncError,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onErrorContainer,
                                    maxLines = 3,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                    if (state.isSyncing || state.syncStatus.isSyncing) {
                        CharkleWavyProgress(
                            progress = (state.syncStatus.progressFraction ?: 0.5).toFloat()
                        )
                    }
                }
            }
        }

        // 2. Appearance & Dual-Zone Color Controls
        SegmentedSection(title = "外观与双区色彩策略") {
            SegmentedRowCard(index = 0, count = 3) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Text("主题模式", style = MaterialTheme.typography.bodyMedium)
                    CharkleConnectedButtonGroup(
                        height = 40.dp,
                        fillWidth = true,
                        modifier = Modifier.fillMaxWidth(),
                        items = listOf(
                            ConnectedActionItem(
                                icon = Icons.Rounded.BrightnessAuto,
                                contentDescription = "跟随系统",
                                label = "系统",
                                checked = state.appearanceMode == CharkleAppearanceMode.System,
                                onClick = { store.setAppearanceMode(CharkleAppearanceMode.System) }
                            ),
                            ConnectedActionItem(
                                icon = Icons.Rounded.LightMode,
                                contentDescription = "浅色",
                                label = "浅色",
                                checked = state.appearanceMode == CharkleAppearanceMode.Light,
                                onClick = { store.setAppearanceMode(CharkleAppearanceMode.Light) }
                            ),
                            ConnectedActionItem(
                                icon = Icons.Rounded.DarkMode,
                                contentDescription = "深色",
                                label = "深色",
                                checked = state.appearanceMode == CharkleAppearanceMode.Dark,
                                onClick = { store.setAppearanceMode(CharkleAppearanceMode.Dark) }
                            )
                        )
                    )
                }
            }

            SegmentedRowCard(index = 1, count = 3) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("控件跟随壁纸动态强调色", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "仅作用于按钮与导航胶囊，画廊底面始终保持纯中性",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Switch(
                    checked = state.followSystemAccentOnControls,
                    onCheckedChange = { store.setFollowSystemAccent(it) }
                )
            }

            SegmentedRowCard(index = 2, count = 3) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("单图预览默认开启原色校对", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        "关闭作品主色氛围融合，以纯黑/中性背景校对色准",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Switch(
                    checked = state.defaultColorProofing,
                    onCheckedChange = { store.setDefaultColorProofing(it) }
                )
            }
        }

        // 3. Cache & Storage Section (with usage bar, 1/2/4/8 GB budget switcher & safe eviction)
        SegmentedSection(title = "本地存储与离线缓存") {
            SegmentedRowCard(index = 0, count = 3) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("缩略图与原图缓存", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                "已缓存原图 ${state.cacheStats.cachedOriginalCount} 项 · 离线置顶 ${state.cacheStats.pinnedAssetCount} 项",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = "${formatStorageBytes(totalUsedBytes)} / ${budgetGbRounded} GB",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                    LinearProgressIndicator(
                        progress = { usageFraction },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(6.dp)
                            .clip(RoundedCornerShape(999.dp)),
                        color = if (usageFraction > 0.85f) {
                            extended.warning
                        } else {
                            MaterialTheme.colorScheme.primary
                        },
                        trackColor = MaterialTheme.colorScheme.surfaceContainerHighest
                    )
                    Text(
                        text = "缩略图 ${formatStorageBytes(state.cacheStats.thumbnailBytes)} · 原图缓存 ${formatStorageBytes(state.cacheStats.originalCacheBytes)} · 置顶保护 ${formatStorageBytes(state.cacheStats.pinnedOfflineBytes)}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            SegmentedRowCard(index = 1, count = 3) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("离线缓存上限", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            text = "超出时自动回收未置顶原图",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    CacheBudgetSelectorRow(
                        selectedGb = budgetGbRounded,
                        presetsGb = CACHE_BUDGET_PRESETS_GB,
                        onSelectGb = { gb ->
                            store.setCacheBudgetGb(gb.toDouble())
                        }
                    )
                }
            }

            SegmentedRowCard(
                index = 2,
                count = 3,
                onClick = { showEvictConfirm = true }
            ) {
                Icon(
                    imageVector = Icons.Rounded.DeleteSweep,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "清理非置顶原图缓存",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary
                    )
                    Text(
                        text = if (reclaimableBytes > 0L) {
                            "预计可释放约 ${formatStorageBytes(reclaimableBytes)}，置顶素材与云端原图不受影响"
                        } else {
                            "当前无可回收的非置顶原图缓存"
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        // 4. About Footer
        SegmentedSection(title = "关于 Charkle Android") {
            SegmentedRowCard(index = 0, count = 1) {
                Column {
                    Text("Charkle for Android", style = MaterialTheme.typography.titleSmall)
                    Text(
                        "核心引擎 v${state.engineVersion} · 兼容桌面端无损同步协议",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        Spacer(Modifier.height(4.dp))
    }

    if (showEvictConfirm) {
        AlertDialog(
            onDismissRequest = { showEvictConfirm = false },
            title = { Text("清理非置顶原图缓存？") },
            text = {
                Text(
                    if (reclaimableBytes > 0L) {
                        "将清理约 ${formatStorageBytes(reclaimableBytes)} 非置顶原图缓存；已离线置顶的素材、缩略图以及云端原图均会安全保留。"
                    } else {
                        "将执行一次缓存回收整理；已离线置顶的素材、缩略图以及云端原图均会安全保留。"
                    }
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showEvictConfirm = false
                        store.evictCacheNow()
                    }
                ) { Text("立即清理") }
            },
            dismissButton = {
                TextButton(onClick = { showEvictConfirm = false }) { Text("取消") }
            }
        )
    }
}

@Composable
private fun CacheBudgetSelectorRow(
    selectedGb: Int,
    presetsGb: List<Int>,
    onSelectGb: (Int) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(2.5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        presetsGb.forEachIndexed { index, gb ->
            val checked = selectedGb == gb
            val interactionSource = remember { MutableInteractionSource() }
            val pressed by interactionSource.collectIsPressedAsState()
            val shape = connectedHorizontalButtonShape(
                index = index,
                count = presetsGb.size,
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
                label = "cacheBudgetBg"
            )
            val fg by animateColorAsState(
                targetValue = if (checked) {
                    MaterialTheme.colorScheme.onPrimary
                } else {
                    MaterialTheme.colorScheme.onSecondaryContainer
                },
                animationSpec = MaterialTheme.motionScheme.fastEffectsSpec(),
                label = "cacheBudgetFg"
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
                        onClick = { onSelectGb(gb) }
                    )
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(
                        text = "${gb} GB",
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1
                    )
                }
            }
        }
    }
}

private fun formatStorageBytes(bytes: Long): String {
    if (bytes <= 0L) return "0 B"
    if (bytes < 1024L) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024.0) return String.format(Locale.US, "%.1f KB", kb)
    val mb = kb / 1024.0
    if (mb < 1024.0) return String.format(Locale.US, "%.1f MB", mb)
    return String.format(Locale.US, "%.2f GB", mb / 1024.0)
}

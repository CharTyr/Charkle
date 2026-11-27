@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class, ExperimentalLayoutApi::class)

package com.charkle.android.ui.search

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Clear
import androidx.compose.material.icons.rounded.Dashboard
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.FilterList
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Tag
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.AssistChip
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.charkle.android.core.AssetDto
import com.charkle.android.core.QuickJumpMatchDto
import com.charkle.android.core.SemanticSearchReportDto
import com.charkle.android.designsystem.CharkleExpressiveLoader
import com.charkle.android.designsystem.CharklePaletteTokens
import com.charkle.android.designsystem.SegmentedRowCard
import com.charkle.android.designsystem.SegmentedSection
import com.charkle.android.designsystem.connectedHorizontalButtonShape
import com.charkle.android.designsystem.parseHexColor
import com.charkle.android.designsystem.rememberExpressiveMorphShape
import com.charkle.android.store.CharkleAppStore
import com.charkle.android.store.CharkleUiState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

private sealed interface HexDraftValidation {
    data object Empty : HexDraftValidation
    data class Valid(val normalizedSixHex: String, val isShortForm: Boolean) : HexDraftValidation
    data object Incomplete : HexDraftValidation
    data class Invalid(val message: String) : HexDraftValidation
}

private fun validateHexDraft(raw: String): HexDraftValidation {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return HexDraftValidation.Empty
    val withoutHash = if (trimmed.startsWith("#")) trimmed.substring(1) else trimmed
    if (withoutHash.isEmpty()) return HexDraftValidation.Incomplete
    val hasIllegal = withoutHash.any { c ->
        c !in '0'..'9' && c !in 'a'..'f' && c !in 'A'..'F'
    }
    if (hasIllegal) {
        return HexDraftValidation.Invalid("仅支持 0-9 与 A-F，请输入 3 位或 6 位色值（如 #F6A 或 #BA6B55）")
    }
    if (withoutHash.length > 6) {
        return HexDraftValidation.Invalid("色值最多 6 位十六进制字符（如 #BA6B55）")
    }
    return when (withoutHash.length) {
        3 -> {
            val upper = withoutHash.uppercase()
            val expanded = "#${upper[0]}${upper[0]}${upper[1]}${upper[1]}${upper[2]}${upper[2]}"
            HexDraftValidation.Valid(normalizedSixHex = expanded, isShortForm = true)
        }
        6 -> HexDraftValidation.Valid(normalizedSixHex = "#${withoutHash.uppercase()}", isShortForm = false)
        else -> HexDraftValidation.Incomplete
    }
}

private data class CompactSegmentItem(
    val icon: ImageVector?,
    val contentDescription: String,
    val label: String,
    val checked: Boolean,
    val onClick: () -> Unit
)

/**
 * Unified 4-Mode Visual Search, Studio Color Filter, Local Semantic Search & Quick Jump Sheet.
 */
@Composable
fun SearchAndFilterSheetContent(
    state: CharkleUiState,
    store: CharkleAppStore,
    onJumpToFolder: (String) -> Unit,
    onJumpToTag: (String) -> Unit,
    onOpenAsset: (AssetDto) -> Unit,
    onOpenPinterest: () -> Unit,
    onDone: () -> Unit
) {
    val coroutineScope = rememberCoroutineScope()
    val keyboardController = LocalSoftwareKeyboardController.current

    var mode by remember { mutableIntStateOf(0) } // 0: Filter/Color, 1: Semantic, 2: Quick Jump
    var hexDraft by remember { mutableStateOf(state.criteria.selectedColorHex.orEmpty()) }
    var hexSubmitError by remember { mutableStateOf<String?>(null) }

    var sliderTolerance by remember { mutableFloatStateOf(state.criteria.colorTolerance.toFloat()) }
    var isDraggingTolerance by remember { mutableStateOf(false) }

    var semanticQuery by remember { mutableStateOf("") }
    var isSearchingSemantic by remember { mutableStateOf(false) }
    var semanticReport by remember { mutableStateOf<SemanticSearchReportDto?>(null) }
    var semanticAttempted by remember { mutableStateOf(false) }

    var jumpQuery by remember { mutableStateOf("") }
    var isSearchingJump by remember { mutableStateOf(false) }
    var jumpMatches by remember { mutableStateOf<List<QuickJumpMatchDto>>(emptyList()) }
    var jumpAttempted by remember { mutableStateOf(false) }

    val criteria = state.criteria
    val hexValidation = remember(hexDraft) { validateHexDraft(hexDraft) }

    // Keep hexDraft synced when user taps a swatch or hits Reset, without hijacking 3-digit typing
    LaunchedEffect(criteria.selectedColorHex) {
        val external = criteria.selectedColorHex
        val currentNormalized = (validateHexDraft(hexDraft) as? HexDraftValidation.Valid)?.normalizedSixHex
        if (external == null) {
            if (currentNormalized != null) {
                hexDraft = ""
                hexSubmitError = null
            }
        } else if (!external.equals(currentNormalized, ignoreCase = true)) {
            hexDraft = external.uppercase()
            hexSubmitError = null
        }
    }

    // Debounce 3-digit shorthand auto-apply so typing a 6-digit hex doesn't trigger a premature query on char 3
    LaunchedEffect(hexDraft) {
        val v = validateHexDraft(hexDraft)
        if (v is HexDraftValidation.Valid && v.isShortForm) {
            delay(260)
            if (!criteria.selectedColorHex.equals(v.normalizedSixHex, ignoreCase = true)) {
                store.setColorFilter(v.normalizedSixHex)
            }
        }
    }

    // Sync tolerance slider from store when user is not actively dragging
    LaunchedEffect(criteria.colorTolerance) {
        if (!isDraggingTolerance) {
            sliderTolerance = criteria.colorTolerance.toFloat()
        }
    }

    // Debounced live store update while dragging tolerance slider
    LaunchedEffect(sliderTolerance, isDraggingTolerance) {
        if (isDraggingTolerance) {
            delay(130)
            if (abs(sliderTolerance.toDouble() - criteria.colorTolerance) >= 0.5) {
                store.setColorTolerance(sliderTolerance.toDouble())
            }
        }
    }

    val toleranceLabel = when {
        sliderTolerance <= 20f -> "极近"
        sliderTolerance <= 34f -> "相近"
        else -> "宽泛"
    }

    LaunchedEffect(semanticQuery, mode) {
        val trimmed = semanticQuery.trim()
        if (mode == 1 && trimmed.isNotEmpty()) {
            isSearchingSemantic = true
            delay(180)
            semanticReport = store.runLocalSemanticSearch(trimmed)
            semanticAttempted = true
            isSearchingSemantic = false
        } else if (trimmed.isEmpty()) {
            isSearchingSemantic = false
            semanticReport = null
            semanticAttempted = false
        }
    }

    LaunchedEffect(jumpQuery, mode) {
        val trimmed = jumpQuery.trim()
        if (mode == 2 && trimmed.isNotEmpty()) {
            isSearchingJump = true
            delay(110)
            jumpMatches = store.runQuickJump(trimmed)
            jumpAttempted = true
            isSearchingJump = false
        } else if (trimmed.isEmpty()) {
            isSearchingJump = false
            jumpMatches = emptyList()
            jumpAttempted = false
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
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = "搜图 · 筛色 · 随处跳转",
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (criteria.hasVisualFilters || criteria.searchQuery.isNotBlank()) {
                    TextButton(
                        onClick = {
                            hexDraft = ""
                            hexSubmitError = null
                            store.clearAllFilters()
                        }
                    ) { Text("重置") }
                }
                TextButton(onClick = onDone) { Text("完成") }
            }
        }

        // Adaptive 4-Mode Expressive Connected Switcher (zero truncation on 360dp & 1.3x font scale)
        AdaptiveConnectedBar(
            modifier = Modifier.fillMaxWidth(),
            items = listOf(
                CompactSegmentItem(
                    icon = Icons.Rounded.FilterList,
                    contentDescription = "筛色与筛选",
                    label = "筛色",
                    checked = mode == 0,
                    onClick = { mode = 0 }
                ),
                CompactSegmentItem(
                    icon = Icons.Rounded.AutoAwesome,
                    contentDescription = "语义搜图",
                    label = "语义",
                    checked = mode == 1,
                    onClick = { mode = 1 }
                ),
                CompactSegmentItem(
                    icon = Icons.Rounded.Bolt,
                    contentDescription = "随处跳转",
                    label = "跳转",
                    checked = mode == 2,
                    onClick = { mode = 2 }
                ),
                CompactSegmentItem(
                    icon = Icons.Rounded.Explore,
                    contentDescription = "Pinterest 无限空间",
                    label = "空间",
                    checked = false,
                    onClick = {
                        onDone()
                        onOpenPinterest()
                    }
                )
            )
        )

        when (mode) {
            0 -> {
                OutlinedTextField(
                    value = criteria.searchQuery,
                    onValueChange = { store.setSearchQuery(it) },
                    placeholder = { Text("关键词、中文拼音、标签或备注…") },
                    leadingIcon = { Icon(Icons.Rounded.Search, contentDescription = null) },
                    trailingIcon = {
                        if (criteria.searchQuery.isNotEmpty()) {
                            IconButton(onClick = { store.setSearchQuery("") }) {
                                Icon(Icons.Rounded.Clear, contentDescription = "清空关键词")
                            }
                        }
                    },
                    singleLine = true,
                    shape = CircleShape,
                    modifier = Modifier.fillMaxWidth()
                )

                // 10 Calibrated Studio Color Swatches (5x2) + Custom #RGB/#RRGGBB + Tolerance Slider
                SegmentedSection(title = "主色调筛选（10 枚工作室色板 + 自定义色值）") {
                    val rowCount = if (criteria.selectedColorHex != null) 3 else 2
                    SegmentedRowCard(index = 0, count = rowCount) {
                        Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(12.dp)
                        ) {
                            CharklePaletteTokens.filterSwatches.chunked(5).forEach { rowHexes ->
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceEvenly
                                ) {
                                    rowHexes.forEach { hex ->
                                        val selected = criteria.selectedColorHex.equals(hex, ignoreCase = true)
                                        val swatchColor = parseHexColor(hex) ?: MaterialTheme.colorScheme.primary
                                        val morphShape = rememberExpressiveMorphShape(
                                            active = selected,
                                            inactivePolygon = MaterialShapes.Circle,
                                            activePolygon = MaterialShapes.Cookie7Sided
                                        )
                                        Box(
                                            contentAlignment = Alignment.Center,
                                            modifier = Modifier
                                                .size(if (selected) 44.dp else 38.dp)
                                                .clip(morphShape)
                                                .background(swatchColor)
                                                .border(
                                                    width = if (selected) 2.dp else 0.75.dp,
                                                    color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
                                                    shape = morphShape
                                                )
                                                .clickable {
                                                    hexSubmitError = null
                                                    store.toggleColorFilter(hex)
                                                }
                                        ) {
                                            if (selected) {
                                                Icon(
                                                    imageVector = Icons.Rounded.Check,
                                                    contentDescription = "已选中",
                                                    tint = if (swatchColor.luminance() > 0.55f) Color(0xFF18191C) else Color.White,
                                                    modifier = Modifier.size(18.dp)
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    SegmentedRowCard(index = 1, count = rowCount) {
                        val previewHex = (hexValidation as? HexDraftValidation.Valid)?.normalizedSixHex
                            ?: criteria.selectedColorHex
                        val previewColor = parseHexColor(previewHex)
                        val errorText = (hexValidation as? HexDraftValidation.Invalid)?.message ?: hexSubmitError
                        val supportingLabel = when {
                            errorText != null -> errorText
                            hexValidation is HexDraftValidation.Incomplete -> "请输入 3 位或 6 位十六进制色值，如 #F6A 或 #BA6B55"
                            hexValidation is HexDraftValidation.Valid && hexValidation.isShortForm ->
                                "已自动展开为 ${hexValidation.normalizedSixHex}"
                            else -> null
                        }

                        Column(modifier = Modifier.fillMaxWidth()) {
                            OutlinedTextField(
                                value = hexDraft,
                                onValueChange = { raw ->
                                    val filtered = raw.replace("\n", "").uppercase()
                                    hexDraft = filtered
                                    hexSubmitError = null
                                    when (val parsed = validateHexDraft(filtered)) {
                                        HexDraftValidation.Empty -> {
                                            if (criteria.selectedColorHex != null) {
                                                store.setColorFilter(null)
                                            }
                                        }
                                        is HexDraftValidation.Valid -> {
                                            if (!parsed.isShortForm) {
                                                store.setColorFilter(parsed.normalizedSixHex)
                                            }
                                        }
                                        else -> Unit
                                    }
                                },
                                placeholder = { Text("自定义色值，如 #F6A 或 #BA6B55") },
                                leadingIcon = {
                                    if (previewColor != null) {
                                        Box(
                                            modifier = Modifier
                                                .size(20.dp)
                                                .clip(CircleShape)
                                                .background(previewColor)
                                                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                                        )
                                    } else {
                                        Icon(
                                            Icons.Rounded.Palette,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                },
                                trailingIcon = {
                                    if (hexDraft.isNotEmpty() || criteria.selectedColorHex != null) {
                                        IconButton(
                                            onClick = {
                                                hexDraft = ""
                                                hexSubmitError = null
                                                store.setColorFilter(null)
                                            }
                                        ) {
                                            Icon(Icons.Rounded.Clear, contentDescription = "清除色值")
                                        }
                                    }
                                },
                                isError = errorText != null,
                                supportingText = supportingLabel?.let { msg -> { Text(msg) } },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                                keyboardActions = KeyboardActions(
                                    onDone = {
                                        when (val parsed = validateHexDraft(hexDraft)) {
                                            is HexDraftValidation.Valid -> {
                                                hexDraft = parsed.normalizedSixHex
                                                hexSubmitError = null
                                                store.setColorFilter(parsed.normalizedSixHex)
                                                keyboardController?.hide()
                                            }
                                            HexDraftValidation.Empty -> {
                                                store.setColorFilter(null)
                                                keyboardController?.hide()
                                            }
                                            HexDraftValidation.Incomplete -> {
                                                hexSubmitError = "色值位数不完整，请输入 3 位或 6 位（如 #F6A 或 #BA6B55）"
                                            }
                                            is HexDraftValidation.Invalid -> {
                                                hexSubmitError = parsed.message
                                            }
                                        }
                                    }
                                ),
                                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                                shape = RoundedCornerShape(14.dp),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }

                    if (criteria.selectedColorHex != null) {
                        val activeHex = criteria.selectedColorHex.uppercase()
                        val activeSwatch = parseHexColor(activeHex) ?: MaterialTheme.colorScheme.primary
                        SegmentedRowCard(index = 2, count = rowCount) {
                            Column(
                                modifier = Modifier.fillMaxWidth(),
                                verticalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(16.dp)
                                                .clip(CircleShape)
                                                .background(activeSwatch)
                                                .border(0.75.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                                        )
                                        Text(
                                            text = "色差容差 · $activeHex",
                                            style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
                                            color = MaterialTheme.colorScheme.onSurface,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                    Surface(
                                        shape = CircleShape,
                                        color = MaterialTheme.colorScheme.primaryContainer
                                    ) {
                                        Text(
                                            text = "$toleranceLabel ${sliderTolerance.roundToInt()} · 命中 ${state.assets.size}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onPrimaryContainer,
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                                        )
                                    }
                                }
                                @Suppress("DEPRECATION")
                                Slider(
                                    value = sliderTolerance,
                                    onValueChange = { next ->
                                        isDraggingTolerance = true
                                        sliderTolerance = next
                                    },
                                    onValueChangeFinished = {
                                        isDraggingTolerance = false
                                        store.setColorTolerance(sliderTolerance.toDouble())
                                    },
                                    valueRange = 10f..55f
                                )
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Text("极近", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text("相近", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text("宽泛", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }

                // Media Kind Adaptive Connected Group
                SegmentedSection(title = "素材类型") {
                    SegmentedRowCard(index = 0, count = 1) {
                        AdaptiveConnectedBar(
                            height = 40.dp,
                            modifier = Modifier.fillMaxWidth(),
                            items = listOf(
                                CompactSegmentItem(
                                    icon = Icons.Rounded.Image,
                                    contentDescription = "图片",
                                    label = "图片",
                                    checked = "image" in criteria.kinds,
                                    onClick = { store.toggleMediaKindFilter("image") }
                                ),
                                CompactSegmentItem(
                                    icon = Icons.Rounded.Videocam,
                                    contentDescription = "视频",
                                    label = "视频",
                                    checked = "video" in criteria.kinds,
                                    onClick = { store.toggleMediaKindFilter("video") }
                                ),
                                CompactSegmentItem(
                                    icon = Icons.Rounded.Language,
                                    contentDescription = "网页",
                                    label = "网页",
                                    checked = "webBookmark" in criteria.kinds,
                                    onClick = { store.toggleMediaKindFilter("webBookmark") }
                                )
                            )
                        )
                    }
                }

                // Minimum Rating Filter (adaptive full-width, zero clipping)
                SegmentedSection(title = "最低评分") {
                    SegmentedRowCard(index = 0, count = 1) {
                        AdaptiveConnectedBar(
                            height = 40.dp,
                            modifier = Modifier.fillMaxWidth(),
                            items = listOf(0, 3, 4, 5).map { stars ->
                                CompactSegmentItem(
                                    icon = if (stars == 0) null else Icons.Rounded.Star,
                                    contentDescription = if (stars == 0) "不限评分" else "$stars 星以上",
                                    label = if (stars == 0) "不限" else "$stars+",
                                    checked = criteria.minRating == stars,
                                    onClick = { store.setMinRatingFilter(stars) }
                                )
                            }
                        )
                    }
                }
            }

            1 -> {
                OutlinedTextField(
                    value = semanticQuery,
                    onValueChange = { semanticQuery = it },
                    placeholder = { Text("输入画面意象，如「暖色调建筑」「深绿极简 UI」…") },
                    leadingIcon = { Icon(Icons.Rounded.AutoAwesome, contentDescription = null) },
                    trailingIcon = {
                        if (semanticQuery.isNotEmpty()) {
                            IconButton(onClick = { semanticQuery = "" }) {
                                Icon(Icons.Rounded.Clear, contentDescription = "清空语义搜索")
                            }
                        }
                    },
                    singleLine = true,
                    shape = CircleShape,
                    modifier = Modifier.fillMaxWidth()
                )

                when {
                    semanticQuery.isBlank() -> {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                text = "本地语义搜图支持色感、构图与画面描述检索，试试：",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            FlowRow(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                listOf("暖色调建筑", "极简界面", "胶片人像", "高对比光影").forEach { suggestion ->
                                    AssistChip(
                                        onClick = { semanticQuery = suggestion },
                                        label = { Text(suggestion) }
                                    )
                                }
                            }
                        }
                    }

                    isSearchingSemantic -> {
                        SegmentedRowCard(index = 0, count = 1) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.Center
                            ) {
                                CharkleExpressiveLoader(modifier = Modifier.size(32.dp))
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    text = "正在本地检索画面意象…",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }

                    else -> {
                        val report = semanticReport
                        if (report == null && semanticAttempted) {
                            SegmentedRowCard(index = 0, count = 1) {
                                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text("语义检索暂未返回结果", style = MaterialTheme.typography.titleSmall)
                                    Text(
                                        "请换个画面描述重试，或先回到素材库确认已完成本地索引。",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        } else if (report != null) {
                            if (report.summary.isNotBlank()) {
                                Text(
                                    text = report.summary,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            if (report.hits.isEmpty()) {
                                SegmentedRowCard(index = 0, count = 1) {
                                    Column(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        Text("未找到匹配的视觉意象", style = MaterialTheme.typography.titleSmall)
                                        Text(
                                            text = if (criteria.hasVisualFilters) {
                                                "当前已叠加颜色或类型筛选，尝试清空筛选或换更宽泛的描述。"
                                            } else {
                                                "尝试更换色感、材质或主体关键词，例如「暖色」「构图」「海报」。"
                                            },
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                        if (criteria.hasVisualFilters) {
                                            TextButton(onClick = { store.clearAllFilters() }) {
                                                Text("清空当前筛选条件")
                                            }
                                        }
                                    }
                                }
                            } else {
                                val displayedHits = report.hits.take(15)
                                SegmentedSection(title = "命中素材 (${report.hits.size})") {
                                    displayedHits.forEachIndexed { idx, hit ->
                                        val thumb = remember(hit.asset.id, state.mediaCacheRevision) {
                                            store.thumbnailFile(hit.asset.id)
                                        }
                                        SegmentedRowCard(
                                            index = idx,
                                            count = displayedHits.size,
                                            onClick = {
                                                onDone()
                                                onOpenAsset(hit.asset)
                                            }
                                        ) {
                                            Box(
                                                modifier = Modifier
                                                    .size(44.dp)
                                                    .clip(RoundedCornerShape(10.dp))
                                                    .background(MaterialTheme.colorScheme.surfaceContainer),
                                                contentAlignment = Alignment.Center
                                            ) {
                                                if (thumb != null) {
                                                    AsyncImage(
                                                        model = thumb,
                                                        contentDescription = hit.asset.title,
                                                        contentScale = ContentScale.Crop,
                                                        modifier = Modifier.matchParentSize()
                                                    )
                                                } else {
                                                    Icon(
                                                        Icons.Rounded.Image,
                                                        contentDescription = null,
                                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        modifier = Modifier.size(20.dp)
                                                    )
                                                }
                                            }
                                            Spacer(Modifier.width(12.dp))
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text(
                                                    hit.asset.title,
                                                    style = MaterialTheme.typography.titleSmall,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis
                                                )
                                                val detail = hit.reason.ifBlank { hit.sourceLabel }
                                                if (detail.isNotBlank()) {
                                                    Text(
                                                        detail,
                                                        style = MaterialTheme.typography.bodySmall,
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis
                                                    )
                                                }
                                            }
                                            Icon(
                                                imageVector = Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                                                contentDescription = null,
                                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                                modifier = Modifier.size(18.dp)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            2 -> {
                OutlinedTextField(
                    value = jumpQuery,
                    onValueChange = { jumpQuery = it },
                    placeholder = { Text("随处跳转：搜文件夹、标签、情绪板或素材…") },
                    leadingIcon = { Icon(Icons.Rounded.Bolt, contentDescription = null) },
                    trailingIcon = {
                        if (jumpQuery.isNotEmpty()) {
                            IconButton(onClick = { jumpQuery = "" }) {
                                Icon(Icons.Rounded.Clear, contentDescription = "清空跳转搜索")
                            }
                        }
                    },
                    singleLine = true,
                    shape = CircleShape,
                    modifier = Modifier.fillMaxWidth()
                )

                when {
                    jumpQuery.isBlank() -> {
                        val quickFolders = state.folders.take(4)
                        val quickBoards = state.boards.take(3)
                        val quickTags = state.tagCounts.take(6)

                        if (quickFolders.isEmpty() && quickBoards.isEmpty() && quickTags.isEmpty()) {
                            SegmentedRowCard(index = 0, count = 1) {
                                Text(
                                    "输入名称即可直达任意文件夹、情绪板、标签或单条素材。",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        } else {
                            if (quickFolders.isNotEmpty()) {
                                SegmentedSection(title = "直达文件夹") {
                                    quickFolders.forEachIndexed { idx, folder ->
                                        SegmentedRowCard(
                                            index = idx,
                                            count = quickFolders.size,
                                            onClick = {
                                                onJumpToFolder(folder.id)
                                                onDone()
                                            }
                                        ) {
                                            Icon(
                                                Icons.Rounded.Folder,
                                                contentDescription = null,
                                                tint = parseHexColor(folder.colorHex) ?: MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.size(19.dp)
                                            )
                                            Spacer(Modifier.width(10.dp))
                                            Text(
                                                folder.name,
                                                style = MaterialTheme.typography.bodyMedium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                                modifier = Modifier.weight(1f)
                                            )
                                            Text(
                                                folder.assetCount.toString(),
                                                style = MaterialTheme.typography.labelMedium,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                        }
                                    }
                                }
                            }
                            if (quickBoards.isNotEmpty()) {
                                SegmentedSection(title = "直达情绪板") {
                                    quickBoards.forEachIndexed { idx, board ->
                                        SegmentedRowCard(
                                            index = idx,
                                            count = quickBoards.size,
                                            onClick = {
                                                store.openMoodboard(board.id)
                                                onDone()
                                            }
                                        ) {
                                            Icon(
                                                Icons.Rounded.Dashboard,
                                                contentDescription = null,
                                                tint = MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.size(19.dp)
                                            )
                                            Spacer(Modifier.width(10.dp))
                                            Text(
                                                board.title,
                                                style = MaterialTheme.typography.bodyMedium,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                                modifier = Modifier.weight(1f)
                                            )
                                            Text(
                                                "${board.itemCount} 项",
                                                style = MaterialTheme.typography.labelMedium,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                        }
                                    }
                                }
                            }
                            if (quickTags.isNotEmpty()) {
                                FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    quickTags.forEach { tc ->
                                        AssistChip(
                                            onClick = {
                                                onJumpToTag(tc.tag)
                                                onDone()
                                            },
                                            label = { Text("#${tc.tag}") }
                                        )
                                    }
                                }
                            }
                        }
                    }

                    isSearchingJump -> {
                        SegmentedRowCard(index = 0, count = 1) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.Center
                            ) {
                                CharkleExpressiveLoader(modifier = Modifier.size(32.dp))
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    text = "正在检索全库…",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }

                    jumpMatches.isEmpty() && jumpAttempted -> {
                        SegmentedRowCard(index = 0, count = 1) {
                            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("未找到匹配项目", style = MaterialTheme.typography.titleSmall)
                                Text(
                                    "没有与「${jumpQuery.trim()}」匹配的文件夹、情绪板、标签或素材。",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }

                    else -> {
                        SegmentedSection(title = "快速跳转结果 (${jumpMatches.size})") {
                            jumpMatches.forEachIndexed { idx, match ->
                                val kindIcon = when (match.kind) {
                                    "folder" -> Icons.Rounded.Folder
                                    "moodboard" -> Icons.Rounded.Dashboard
                                    "tag" -> Icons.Rounded.Tag
                                    else -> Icons.Rounded.Image
                                }
                                val kindLabel = when (match.kind) {
                                    "folder" -> "文件夹"
                                    "moodboard" -> "情绪板"
                                    "tag" -> "标签"
                                    else -> "素材"
                                }
                                SegmentedRowCard(
                                    index = idx,
                                    count = jumpMatches.size,
                                    onClick = {
                                        when (match.kind) {
                                            "folder" -> {
                                                match.targetUuid?.let { onJumpToFolder(it) }
                                                onDone()
                                            }
                                            "moodboard" -> {
                                                match.targetUuid?.let { store.openMoodboard(it) }
                                                onDone()
                                            }
                                            "tag" -> {
                                                val tagName = match.tagName?.takeIf { it.isNotBlank() }
                                                    ?: match.title.removePrefix("#")
                                                onJumpToTag(tagName)
                                                onDone()
                                            }
                                            "asset" -> {
                                                val uuid = match.targetUuid
                                                val localHit = state.assets.firstOrNull {
                                                    it.id.equals(uuid, ignoreCase = true)
                                                }
                                                if (localHit != null) {
                                                    onDone()
                                                    onOpenAsset(localHit)
                                                } else if (!uuid.isNullOrBlank()) {
                                                    coroutineScope.launch {
                                                        val fetched = runCatching {
                                                            store.repository.fetchAsset(uuid)
                                                        }.getOrNull()
                                                        onDone()
                                                        if (fetched != null) {
                                                            onOpenAsset(fetched)
                                                        } else {
                                                            store.showToast("未能定位该素材")
                                                        }
                                                    }
                                                } else {
                                                    onDone()
                                                }
                                            }
                                            else -> onDone()
                                        }
                                    }
                                ) {
                                    Icon(
                                        imageVector = kindIcon,
                                        contentDescription = kindLabel,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(19.dp)
                                    )
                                    Spacer(Modifier.width(10.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            match.title,
                                            style = MaterialTheme.typography.titleSmall,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                        if (match.subtitle.isNotBlank()) {
                                            Text(
                                                match.subtitle,
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                    }
                                    Spacer(Modifier.width(8.dp))
                                    Surface(
                                        shape = CircleShape,
                                        color = MaterialTheme.colorScheme.secondaryContainer
                                    ) {
                                        Text(
                                            text = kindLabel,
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSecondaryContainer,
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(4.dp))
    }
}

/**
 * Compact responsive M3 Expressive connected bar that dynamically tightens spacing or stacks
 * icon + label on narrow viewports / large font scales so labels never clip or truncate.
 */
@Composable
private fun AdaptiveConnectedBar(
    items: List<CompactSegmentItem>,
    modifier: Modifier = Modifier,
    height: Dp = 42.dp
) {
    val fontScale = LocalDensity.current.fontScale
    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val count = items.size.coerceAtLeast(1)
        val perSlotWidth = (maxWidth - 2.5.dp * (count - 1)) / count
        val useStacked = perSlotWidth < 70.dp || (perSlotWidth < 84.dp && fontScale > 1.2f)
        val effectiveHeight = if (useStacked) 54.dp else height

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(2.5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            items.forEachIndexed { index, item ->
                val interactionSource = remember { MutableInteractionSource() }
                val pressed by interactionSource.collectIsPressedAsState()
                val shape = connectedHorizontalButtonShape(
                    index = index,
                    count = items.size,
                    isChecked = item.checked,
                    isPressed = pressed
                )
                val bg by animateColorAsState(
                    targetValue = if (item.checked) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.secondaryContainer
                    },
                    animationSpec = MaterialTheme.motionScheme.fastEffectsSpec(),
                    label = "adaptiveConnectedBg"
                )
                val fg by animateColorAsState(
                    targetValue = if (item.checked) {
                        MaterialTheme.colorScheme.onPrimary
                    } else {
                        MaterialTheme.colorScheme.onSecondaryContainer
                    },
                    animationSpec = MaterialTheme.motionScheme.fastEffectsSpec(),
                    label = "adaptiveConnectedFg"
                )

                Surface(
                    color = bg,
                    contentColor = fg,
                    shape = shape,
                    modifier = Modifier
                        .weight(1f)
                        .height(effectiveHeight)
                        .clip(shape)
                        .clickable(
                            interactionSource = interactionSource,
                            indication = null,
                            onClick = item.onClick
                        )
                ) {
                    if (useStacked && item.icon != null) {
                        Column(
                            modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center
                        ) {
                            Icon(
                                imageVector = item.icon,
                                contentDescription = item.contentDescription,
                                modifier = Modifier.size(17.dp)
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                text = item.label,
                                style = MaterialTheme.typography.labelSmall,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    } else {
                        val tightPadding = if (perSlotWidth < 92.dp) 6.dp else 10.dp
                        val iconSize = if (perSlotWidth < 92.dp) 16.dp else 18.dp
                        Row(
                            modifier = Modifier.padding(horizontal = tightPadding),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center
                        ) {
                            if (item.icon != null) {
                                Icon(
                                    imageVector = item.icon,
                                    contentDescription = item.contentDescription,
                                    modifier = Modifier.size(iconSize)
                                )
                                Spacer(Modifier.width(4.dp))
                            }
                            Text(
                                text = item.label,
                                style = if (perSlotWidth < 86.dp) {
                                    MaterialTheme.typography.labelMedium
                                } else {
                                    MaterialTheme.typography.labelLarge
                                },
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }
        }
    }
}

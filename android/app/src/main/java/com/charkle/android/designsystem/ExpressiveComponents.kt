@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.charkle.android.designsystem

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Badge
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.material3.toPath
import androidx.compose.material3.toShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.graphics.shapes.Morph
import androidx.graphics.shapes.RoundedPolygon

private object PolygonMorphCache {
    private val morphEntries = mutableListOf<Triple<RoundedPolygon, RoundedPolygon, Morph>>()

    @Synchronized
    fun getOrCreateMorph(start: RoundedPolygon, end: RoundedPolygon): Morph {
        for ((a, b, m) in morphEntries) {
            if (a === start && b === end) return m
        }
        return Morph(start, end).also { morphEntries.add(Triple(start, end, it)) }
    }
}

/**
 * Material 3 Expressive organic shape morphing between two [MaterialShapes] polygons
 * (e.g. `Circle` <-> `Cookie7Sided`, `Circle` <-> `Cookie9Sided`, `Circle` <-> `Sunny`).
 * Implements structural equality and caches the last scaled outline per size to minimize allocations.
 */
class CharkleMorphingPolygonShape(
    private val morph: Morph,
    private val progress: Float
) : Shape {
    private var lastSize: Size = Size.Unspecified
    private var lastOutline: Outline? = null
    private val scaleMatrix = Matrix()

    override fun createOutline(
        size: Size,
        layoutDirection: LayoutDirection,
        density: Density
    ): Outline {
        val cached = lastOutline
        if (cached != null && lastSize == size) return cached

        val path = morph.toPath(progress.coerceIn(0f, 1f), Path())
        scaleMatrix.reset()
        scaleMatrix.scale(size.width, size.height)
        path.transform(scaleMatrix)
        return Outline.Generic(path).also {
            lastSize = size
            lastOutline = it
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CharkleMorphingPolygonShape) return false
        return morph === other.morph && progress == other.progress
    }

    override fun hashCode(): Int {
        var result = System.identityHashCode(morph)
        result = 31 * result + progress.hashCode()
        return result
    }
}

@Composable
fun rememberExpressiveMorphShape(
    active: Boolean,
    inactivePolygon: RoundedPolygon = MaterialShapes.Circle,
    activePolygon: RoundedPolygon = MaterialShapes.Cookie7Sided
): Shape {
    val reduceMotion = LocalCharkleReduceMotion.current
    val morph = remember(inactivePolygon, activePolygon) {
        PolygonMorphCache.getOrCreateMorph(inactivePolygon, activePolygon)
    }
    val inactiveShape = if (inactivePolygon === MaterialShapes.Circle) {
        CircleShape
    } else {
        inactivePolygon.toShape()
    }
    val activeShape = if (activePolygon === MaterialShapes.Circle) {
        CircleShape
    } else {
        activePolygon.toShape()
    }
    val progress by animateFloatAsState(
        targetValue = if (active) 1f else 0f,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "expressivePolygonMorph"
    )
    return when {
        progress <= 0.001f -> inactiveShape
        progress >= 0.999f -> activeShape
        else -> remember(morph, progress) { CharkleMorphingPolygonShape(morph, progress) }
    }
}

/**
 * Computes Material 3 Expressive segmented list corner shape (20dp outer caps, 4dp inner joints).
 */
fun segmentedCardShape(index: Int, count: Int, outer: Dp = 20.dp, inner: Dp = 4.dp): Shape {
    if (count <= 1) return RoundedCornerShape(outer)
    return when (index) {
        0 -> RoundedCornerShape(topStart = outer, topEnd = outer, bottomStart = inner, bottomEnd = inner)
        count - 1 -> RoundedCornerShape(topStart = inner, topEnd = inner, bottomStart = outer, bottomEnd = outer)
        else -> RoundedCornerShape(inner)
    }
}

/**
 * Computes Material 3 Expressive connected horizontal pill button shape (outer full pill, inner morphing corners).
 */
@Composable
fun connectedHorizontalButtonShape(
    index: Int,
    count: Int,
    isChecked: Boolean,
    isPressed: Boolean,
    outer: Dp = 24.dp,
    innerDefault: Dp = 6.dp
): Shape {
    val reduceMotion = LocalCharkleReduceMotion.current
    val innerRadius by animateDpAsState(
        targetValue = when {
            isChecked -> outer
            isPressed -> 12.dp
            else -> innerDefault
        },
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "connectedInnerRadius"
    )
    if (count <= 1) return RoundedCornerShape(outer)
    return when (index) {
        0 -> RoundedCornerShape(
            topStart = outer,
            bottomStart = outer,
            topEnd = innerRadius,
            bottomEnd = innerRadius
        )
        count - 1 -> RoundedCornerShape(
            topStart = innerRadius,
            bottomStart = innerRadius,
            topEnd = outer,
            bottomEnd = outer
        )
        else -> RoundedCornerShape(innerRadius)
    }
}

data class ConnectedActionItem(
    val icon: ImageVector,
    val contentDescription: String,
    val label: String? = null,
    val checked: Boolean = false,
    val emphasized: Boolean = false,
    val organicActiveShape: Boolean = false,
    val onClick: () -> Unit
)

/**
 * Expressive Connected Button Group inspired by Material 3 Expressive:
 * outer rounded pill ends, tight 6dp interior joints with 2.5dp gaps and spring corner morphing.
 * Optionally morphs checked icon-only tiles into an organic `Cookie7Sided` badge.
 */
@Composable
fun CharkleConnectedButtonGroup(
    items: List<ConnectedActionItem>,
    modifier: Modifier = Modifier,
    height: Dp = 44.dp,
    fillWidth: Boolean = false,
    containerColor: Color = MaterialTheme.colorScheme.secondaryContainer,
    contentColor: Color = MaterialTheme.colorScheme.onSecondaryContainer,
    checkedContainerColor: Color = MaterialTheme.colorScheme.primary,
    checkedContentColor: Color = MaterialTheme.colorScheme.onPrimary
) {
    val reduceMotion = LocalCharkleReduceMotion.current
    val isCompactDenseBar = fillWidth && items.size >= 4
    val touchRipple = remember { ripple() }
    val activeCookieShape = MaterialShapes.Cookie7Sided.toShape()
    val circleToCookieMorph = remember {
        PolygonMorphCache.getOrCreateMorph(MaterialShapes.Circle, MaterialShapes.Cookie7Sided)
    }

    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(2.5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        items.forEachIndexed { index, item ->
            val interactionSource = remember { MutableInteractionSource() }
            val pressed by interactionSource.collectIsPressedAsState()
            val isActive = item.checked || item.emphasized
            val supportsOrganic = item.organicActiveShape && item.label == null && !fillWidth

            val connectedShape = connectedHorizontalButtonShape(
                index = index,
                count = items.size,
                isChecked = isActive,
                isPressed = pressed
            )
            // Keep morph state alive unconditionally for organic-capable items so activating genuinely springs.
            val organicMorphProgress by animateFloatAsState(
                targetValue = if (supportsOrganic && isActive) 1f else 0f,
                animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
                label = "connectedOrganicMorph"
            )
            val shape = if (supportsOrganic && (isActive || organicMorphProgress > 0.01f)) {
                when {
                    organicMorphProgress >= 0.999f -> activeCookieShape
                    organicMorphProgress <= 0.001f -> CircleShape
                    else -> remember(circleToCookieMorph, organicMorphProgress) {
                        CharkleMorphingPolygonShape(circleToCookieMorph, organicMorphProgress)
                    }
                }
            } else {
                connectedShape
            }

            val bg by animateColorAsState(
                targetValue = if (isActive) checkedContainerColor else containerColor,
                animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
                label = "connectedBg"
            )
            val fg by animateColorAsState(
                targetValue = if (isActive) checkedContentColor else contentColor,
                animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
                label = "connectedFg"
            )

            Surface(
                color = bg,
                contentColor = fg,
                shape = shape,
                modifier = Modifier
                    .then(if (fillWidth) Modifier.weight(1f) else Modifier)
                    .defaultMinSize(minWidth = height, minHeight = height)
                    .clip(shape)
                    .semantics {
                        this.selected = isActive
                        if (item.label != null && item.contentDescription != item.label) {
                            this.contentDescription = item.contentDescription
                        }
                    }
                    .clickable(
                        interactionSource = interactionSource,
                        indication = touchRipple,
                        role = Role.Button,
                        onClick = item.onClick
                    )
            ) {
                val hPad = when {
                    isCompactDenseBar && item.label != null -> 6.dp
                    item.label != null -> 12.dp
                    else -> 11.dp
                }
                Row(
                    modifier = Modifier.padding(horizontal = hPad, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center
                ) {
                    Icon(
                        imageVector = item.icon,
                        contentDescription = if (item.label == null) item.contentDescription else null,
                        modifier = Modifier.size(if (isCompactDenseBar && item.label != null) 17.dp else 19.dp)
                    )
                    if (item.label != null) {
                        Spacer(Modifier.width(if (isCompactDenseBar) 4.dp else 6.dp))
                        Text(
                            text = item.label,
                            style = if (isCompactDenseBar) {
                                MaterialTheme.typography.labelMedium
                            } else {
                                MaterialTheme.typography.labelLarge
                            },
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
}

/**
 * Tactile Material 3 Expressive pill toggle chip (zero grey hairline borders; high-contrast active dark/primary
 * fill paired with soft tonal inactive fill and spring corner morphing).
 */
@Composable
fun ExpressivePillToggleChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
    swatchColor: Color? = null,
    selectedContainerColor: Color = MaterialTheme.colorScheme.primary,
    selectedContentColor: Color = MaterialTheme.colorScheme.onPrimary,
    unselectedContainerColor: Color = MaterialTheme.colorScheme.surfaceContainerHigh,
    unselectedContentColor: Color = MaterialTheme.colorScheme.onSurface
) {
    val reduceMotion = LocalCharkleReduceMotion.current
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val touchRipple = remember { ripple() }

    val corner by animateDpAsState(
        targetValue = when {
            pressed -> 11.dp
            selected -> 12.dp
            else -> 22.dp
        },
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "expressiveChipCorner"
    )
    val bg by animateColorAsState(
        targetValue = if (selected) selectedContainerColor else unselectedContainerColor,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
        label = "expressiveChipBg"
    )
    val fg by animateColorAsState(
        targetValue = if (selected) selectedContentColor else unselectedContentColor,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
        label = "expressiveChipFg"
    )
    val shape = RoundedCornerShape(corner)
    val swatchBorderColor = if (selected) {
        selectedContentColor.copy(alpha = 0.65f)
    } else {
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.24f)
    }

    Surface(
        shape = shape,
        color = bg,
        contentColor = fg,
        modifier = modifier
            .defaultMinSize(minHeight = 36.dp)
            .clip(shape)
            .semantics { this.selected = selected }
            .clickable(
                interactionSource = interactionSource,
                indication = touchRipple,
                role = Role.Button,
                onClick = onClick
            )
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 13.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)
        ) {
            if (swatchColor != null) {
                Box(
                    modifier = Modifier
                        .size(13.dp)
                        .clip(CircleShape)
                        .background(swatchColor)
                        .border(1.2.dp, swatchBorderColor, CircleShape)
                )
            } else if (leadingIcon != null) {
                Icon(leadingIcon, contentDescription = null, modifier = Modifier.size(15.dp))
            }
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/**
 * Circular tonal navigation button wrapped by an animated Material 3 Expressive progress arc
 * (e.g. showing deck position 3/10 around the Next arrow).
 */
@Composable
fun ExpressiveProgressRingButton(
    icon: ImageVector,
    contentDescription: String,
    progress: Float,
    enabled: Boolean = true,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    size: Dp = 44.dp,
    containerColor: Color = MaterialTheme.colorScheme.primaryContainer,
    contentColor: Color = MaterialTheme.colorScheme.onPrimaryContainer,
    ringColor: Color = MaterialTheme.colorScheme.primary
) {
    val reduceMotion = LocalCharkleReduceMotion.current
    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "progressRing"
    )
    val trackColor = contentColor.copy(alpha = 0.16f)

    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(containerColor.copy(alpha = if (enabled) 1f else 0.55f))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize().padding(3.dp)) {
            val strokeWidth = 2.6.dp.toPx()
            val inset = strokeWidth / 2f
            val arcSize = Size(this.size.width - strokeWidth, this.size.height - strokeWidth)
            val stroke = Stroke(width = strokeWidth, cap = StrokeCap.Round)
            drawArc(
                color = trackColor,
                startAngle = -90f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = stroke
            )
            drawArc(
                color = ringColor,
                startAngle = -90f,
                sweepAngle = 360f * animatedProgress,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = stroke
            )
        }
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = contentColor.copy(alpha = if (enabled) 1f else 0.45f),
            modifier = Modifier.size(22.dp)
        )
    }
}

/**
 * Signature Material 3 Expressive 3-unit Hero Action Deck:
 * Wide rounded-pill flanks (`CircleShape`, tonal container) framing a high-contrast squircle center block
 * (`18dp` radius morphing smoothly toward `30dp` on press, deep `primary` fill).
 */
@Composable
fun ExpressiveHeroTransportRow(
    leadingIcon: ImageVector,
    leadingDescription: String,
    leadingEnabled: Boolean = true,
    onLeadingClick: () -> Unit,
    centerIcon: ImageVector,
    centerLabel: String,
    onCenterClick: () -> Unit,
    trailingIcon: ImageVector,
    trailingDescription: String,
    trailingEnabled: Boolean = true,
    trailingProgress: Float? = null,
    onTrailingClick: () -> Unit,
    modifier: Modifier = Modifier,
    leadingContainerColor: Color = MaterialTheme.colorScheme.primaryContainer,
    leadingContentColor: Color = MaterialTheme.colorScheme.onPrimaryContainer,
    trailingContainerColor: Color = MaterialTheme.colorScheme.primaryContainer,
    trailingContentColor: Color = MaterialTheme.colorScheme.onPrimaryContainer
) {
    val reduceMotion = LocalCharkleReduceMotion.current
    val centerInteraction = remember { MutableInteractionSource() }
    val centerPressed by centerInteraction.collectIsPressedAsState()
    val touchRipple = remember { ripple() }

    val centerRadius by animateDpAsState(
        targetValue = if (centerPressed) 30.dp else 18.dp,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "heroCenterMorph"
    )
    val animatedArc by animateFloatAsState(
        targetValue = (trailingProgress ?: 0f).coerceIn(0f, 1f),
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "heroTrailingArc"
    )

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Surface(
            onClick = onLeadingClick,
            enabled = leadingEnabled,
            shape = CircleShape,
            color = leadingContainerColor.copy(alpha = if (leadingEnabled) 1f else 0.52f),
            contentColor = leadingContentColor.copy(alpha = if (leadingEnabled) 1f else 0.45f),
            modifier = Modifier
                .width(78.dp)
                .height(62.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    imageVector = leadingIcon,
                    contentDescription = leadingDescription,
                    modifier = Modifier.size(26.dp)
                )
            }
        }

        val centerShape = RoundedCornerShape(centerRadius)
        Surface(
            shape = centerShape,
            color = MaterialTheme.colorScheme.primary,
            contentColor = MaterialTheme.colorScheme.onPrimary,
            modifier = Modifier
                .weight(1f)
                .height(62.dp)
                .clip(centerShape)
                .clickable(
                    interactionSource = centerInteraction,
                    indication = touchRipple,
                    role = Role.Button,
                    onClick = onCenterClick
                )
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                modifier = Modifier.padding(horizontal = 14.dp)
            ) {
                Icon(centerIcon, contentDescription = null, modifier = Modifier.size(21.dp))
                Text(
                    text = centerLabel,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }

        val ringColor = MaterialTheme.colorScheme.primary
        val ringTrack = trailingContentColor.copy(alpha = 0.16f)
        Surface(
            onClick = onTrailingClick,
            enabled = trailingEnabled,
            shape = CircleShape,
            color = trailingContainerColor.copy(alpha = if (trailingEnabled) 1f else 0.52f),
            contentColor = trailingContentColor.copy(alpha = if (trailingEnabled) 1f else 0.45f),
            modifier = Modifier
                .width(78.dp)
                .height(62.dp)
        ) {
            Box(contentAlignment = Alignment.Center) {
                if (trailingProgress != null) {
                    Canvas(modifier = Modifier.size(46.dp)) {
                        val strokeWidth = 2.6.dp.toPx()
                        val inset = strokeWidth / 2f
                        val arcSize = Size(size.width - strokeWidth, size.height - strokeWidth)
                        val stroke = Stroke(width = strokeWidth, cap = StrokeCap.Round)
                        drawArc(
                            color = ringTrack,
                            startAngle = -90f,
                            sweepAngle = 360f,
                            useCenter = false,
                            topLeft = Offset(inset, inset),
                            size = arcSize,
                            style = stroke
                        )
                        drawArc(
                            color = ringColor,
                            startAngle = -90f,
                            sweepAngle = 360f * animatedArc,
                            useCenter = false,
                            topLeft = Offset(inset, inset),
                            size = arcSize,
                            style = stroke
                        )
                    }
                }
                Icon(
                    imageVector = trailingIcon,
                    contentDescription = trailingDescription,
                    modifier = Modifier.size(26.dp)
                )
            }
        }
    }
}

data class FloatingNavDestination(
    val id: String,
    val label: String,
    val icon: ImageVector,
    val activeIcon: ImageVector,
    val badgeCount: Int = 0
)

/**
 * Dual-island Material 3 Expressive floating bottom dock for Phone:
 * Left floating pill (`素材库 / 收件箱 / 情绪板`) + Right detached organic morphing FAB
 * (smoothly morphs Circle -> `Cookie9Sided` with spring rotation when search/filters are active).
 */
@Composable
fun CharkleFloatingNavDock(
    destinations: List<FloatingNavDestination>,
    activeId: String,
    onSelect: (String) -> Unit,
    onReselectLibrary: () -> Unit,
    companionIcon: ImageVector,
    companionDescription: String,
    companionActive: Boolean,
    onCompanionClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val reduceMotion = LocalCharkleReduceMotion.current
    val companionShape = rememberExpressiveMorphShape(
        active = companionActive,
        inactivePolygon = MaterialShapes.Circle,
        activePolygon = MaterialShapes.Cookie9Sided
    )
    val companionRotation by animateFloatAsState(
        targetValue = if (companionActive && !reduceMotion) 20f else 0f,
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "companionRotation"
    )
    val companionBg by animateColorAsState(
        targetValue = if (companionActive) {
            MaterialTheme.colorScheme.primary
        } else {
            MaterialTheme.colorScheme.primaryContainer
        },
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
        label = "companionBg"
    )
    val companionFg by animateColorAsState(
        targetValue = if (companionActive) {
            MaterialTheme.colorScheme.onPrimary
        } else {
            MaterialTheme.colorScheme.onPrimaryContainer
        },
        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
        label = "companionFg"
    )

    val isDark = LocalCharkleExtendedColors.current.isDark
    val dockContainerColor = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh
    } else {
        MaterialTheme.colorScheme.surfaceContainerLowest
    }

    Row(
        modifier = modifier.padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Surface(
            shape = CircleShape,
            color = dockContainerColor,
            tonalElevation = 2.dp,
            shadowElevation = 8.dp,
            modifier = Modifier
                .weight(1f, fill = false)
                .then(
                    if (isDark) {
                        Modifier.border(0.75.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                    } else {
                        Modifier
                    }
                )
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 5.dp, vertical = 5.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                destinations.forEach { dest ->
                    val selected = dest.id == activeId
                    val pillBg by animateColorAsState(
                        targetValue = if (selected) {
                            MaterialTheme.colorScheme.primaryContainer
                        } else {
                            Color.Transparent
                        },
                        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
                        label = "navPillBg"
                    )
                    val pillFg by animateColorAsState(
                        targetValue = if (selected) {
                            MaterialTheme.colorScheme.onPrimaryContainer
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        animationSpec = if (reduceMotion) snap() else MaterialTheme.motionScheme.fastEffectsSpec(),
                        label = "navPillFg"
                    )

                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(pillBg)
                            .semantics {
                                this.selected = selected
                                if (dest.badgeCount > 0) {
                                    this.contentDescription = "${dest.label}，${dest.badgeCount} 项待整理"
                                }
                            }
                            .clickable(role = Role.Tab) {
                                if (selected && dest.id == "library") {
                                    onReselectLibrary()
                                } else {
                                    onSelect(dest.id)
                                }
                            }
                            .padding(horizontal = 10.dp, vertical = 10.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                imageVector = if (selected) dest.activeIcon else dest.icon,
                                contentDescription = null,
                                tint = pillFg,
                                modifier = Modifier.size(20.dp)
                            )
                            Text(
                                text = dest.label,
                                style = MaterialTheme.typography.labelLarge,
                                color = pillFg,
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (dest.badgeCount > 0) {
                                Badge(
                                    containerColor = MaterialTheme.colorScheme.primary,
                                    contentColor = MaterialTheme.colorScheme.onPrimary
                                ) {
                                    Text(
                                        text = if (dest.badgeCount > 99) "99+" else dest.badgeCount.toString(),
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1,
                                        softWrap = false
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        // Cast shadow exclusively from an inscribed convex CircleShape plate underneath:
        // Android HWUI's concave shadow tessellator (`stitchConcaveRings`) can hang RenderThread
        // when `shadowElevation > 0` is applied directly to concave polygons like `Cookie9Sided`.
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(56.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(46.dp)
                    .shadow(elevation = 8.dp, shape = CircleShape, clip = false)
                    .background(companionBg, CircleShape)
            )
            Surface(
                onClick = onCompanionClick,
                shape = companionShape,
                color = companionBg,
                contentColor = companionFg,
                shadowElevation = 0.dp,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer { rotationZ = companionRotation }
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.graphicsLayer { rotationZ = -companionRotation }
                ) {
                    Icon(
                        imageVector = companionIcon,
                        contentDescription = companionDescription,
                        modifier = Modifier.size(22.dp)
                    )
                }
            }
        }
    }
}

/**
 * Material 3 Expressive segmented rounded card section (2dp gap between rows, 20dp outer / 4dp inner radii).
 */
@Composable
fun SegmentedSection(
    title: String? = null,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(modifier = modifier.fillMaxWidth()) {
        if (!title.isNullOrBlank()) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 12.dp, bottom = 8.dp)
            )
        }
        Column(
            verticalArrangement = Arrangement.spacedBy(2.dp),
            content = content
        )
    }
}

@Composable
fun SegmentedRowCard(
    index: Int,
    count: Int,
    onClick: (() -> Unit)? = null,
    containerColor: Color = if (LocalCharkleExtendedColors.current.isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh
    } else {
        MaterialTheme.colorScheme.surfaceContainerLowest
    },
    contentPadding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
    content: @Composable RowScope.() -> Unit
) {
    val shape = remember(index, count) { segmentedCardShape(index, count) }
    val mod = if (onClick != null) {
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(role = Role.Button, onClick = onClick)
    } else {
        Modifier.fillMaxWidth()
    }
    Surface(
        shape = shape,
        color = containerColor,
        modifier = mod
    ) {
        Row(
            modifier = Modifier.padding(contentPadding),
            verticalAlignment = Alignment.CenterVertically,
            content = content
        )
    }
}

@Composable
fun CharkleExpressiveLoader(modifier: Modifier = Modifier) {
    LoadingIndicator(
        modifier = modifier.size(44.dp),
        color = MaterialTheme.colorScheme.primary
    )
}

@Composable
fun CharkleWavyProgress(
    progress: Float,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.primary,
    trackColor: Color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f)
) {
    LinearWavyProgressIndicator(
        progress = { progress.coerceIn(0f, 1f) },
        modifier = modifier.fillMaxWidth(),
        color = color,
        trackColor = trackColor
    )
}

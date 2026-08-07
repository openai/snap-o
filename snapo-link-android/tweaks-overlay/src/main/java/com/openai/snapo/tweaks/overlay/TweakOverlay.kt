package com.openai.snapo.tweaks.overlay

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.structuralEqualityPolicy
import androidx.compose.ui.AbsoluteAlignment
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openai.snapo.tweaks.SnapOTweakEntry
import com.openai.snapo.tweaks.SnapOTweakValue
import com.openai.snapo.tweaks.SnapOTweaks
import kotlin.math.roundToInt

private val OverlayMinimumHeight = 160.dp
private val OverlayMaximumWidth = 480.dp
private val OverlayHorizontalMargin = 16.dp
private val OverlayButtonSize = 52.dp

internal object TweakOverlayColors {
    val surface = Color(0xFFFFFFFF)
    val foreground = Color(0xFF18212F)
    val secondary = Color(0xFF727783)
    val outline = Color(0xFFE2E4E8)
    val field = Color(0xFFF5F6F8)
}

/** Draws a compact, movable tweak inspector over application content. */
@Composable
fun SnapOTweakOverlay(modifier: Modifier = Modifier) {
    val appContext = LocalContext.current.applicationContext
    LaunchedEffect(appContext) {
        SnapOTweakOverlaySettings.initialize(appContext)
    }

    if (!SnapOTweakOverlaySettings.isEnabled) return

    val tweaks = rememberActiveOverlayTweaks()
    if (tweaks.isNotEmpty()) {
        TweakOverlayLayer(
            tweaks = tweaks,
            modifier = modifier.fillMaxSize(),
        )
    }
}

@Composable
private fun TweakOverlayLayer(
    tweaks: List<SnapOTweakEntry>,
    modifier: Modifier = Modifier,
) {
    var isExpanded by rememberSaveable { mutableStateOf(false) }
    val bounds = remember { TweakOverlayBounds() }
    val onVerticalDrag: (Float) -> Unit = { change ->
        val travel = bounds.verticalTravel(isExpanded)
        if (travel > 0) {
            SnapOTweakOverlaySettings.offsetVerticalPosition(change / travel)
        }
    }

    Box(
        modifier = modifier
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .measureOverlaySize { bounds.containerSize = it },
    ) {
        if (isExpanded) {
            ExpandedTweakOverlay(
                tweaks = tweaks,
                height = TweakOverlayLayout.height.coerceAtLeast(OverlayMinimumHeight),
                onDrag = onVerticalDrag,
                onMinimize = { isExpanded = false },
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .measureOverlaySize { bounds.panelSize = it }
                    .offset {
                        val position = SnapOTweakOverlaySettings.verticalPosition
                        IntOffset(
                            x = 0,
                            y = (position * bounds.verticalTravel(isExpanded)).roundToInt()
                        )
                    }
                    .padding(horizontal = OverlayHorizontalMargin)
                    .width(OverlayMaximumWidth),
            )
        } else {
            MinimizedTweakOverlay(
                onExpand = { isExpanded = true },
                onDrag = { drag ->
                    if (bounds.horizontalTravel > 0) {
                        val position =
                            SnapOTweakOverlaySettings.horizontalPosition + drag.x / bounds.horizontalTravel
                        SnapOTweakOverlaySettings.updateHorizontalPosition(position)
                    }
                    onVerticalDrag(drag.y)
                },
                modifier = Modifier
                    .align(AbsoluteAlignment.TopLeft)
                    .measureOverlaySize { bounds.buttonSize = it }
                    .overlayButtonOffset(bounds, isExpanded),
            )
        }
    }
}

@Composable
private fun resolveSelectedColorTweak(
    name: String?,
    tweaks: List<SnapOTweakEntry>,
    onMissing: () -> Unit,
): SnapOTweakEntry? {
    val selected = name?.let { selectedName ->
        tweaks.firstOrNull { tweak ->
            tweak.name == selectedName && tweak.defaultValue is SnapOTweakValue.ColorValue
        }
    }

    LaunchedEffect(name, selected) {
        if (name != null && selected == null) onMissing()
    }

    return selected
}

@Composable
private fun Modifier.measureOverlaySize(
    onSizeMeasured: (IntSize) -> Unit,
): Modifier = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    onSizeMeasured(IntSize(placeable.width, placeable.height))

    layout(placeable.width, placeable.height) {
        placeable.placeRelative(0, 0)
    }
}

@Composable
private fun Modifier.overlayButtonOffset(
    bounds: TweakOverlayBounds,
    isExpanded: Boolean,
): Modifier = absoluteOffset {
    IntOffset(
        x = (SnapOTweakOverlaySettings.horizontalPosition * bounds.horizontalTravel).roundToInt(),
        y = (SnapOTweakOverlaySettings.verticalPosition * bounds.verticalTravel(isExpanded)).roundToInt(),
    )
}

@Composable
private fun ExpandedTweakOverlay(
    tweaks: List<SnapOTweakEntry>,
    height: Dp,
    onDrag: (Float) -> Unit,
    onMinimize: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedColorTweakName by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedColorTweak = resolveSelectedColorTweak(
        name = selectedColorTweakName,
        tweaks = tweaks,
    ) {
        selectedColorTweakName = null
    }

    Surface(
        modifier = modifier.height(height),
        shape = RoundedCornerShape(14.dp),
        color = TweakOverlayColors.surface,
        contentColor = TweakOverlayColors.foreground,
        border = BorderStroke(1.dp, TweakOverlayColors.outline),
        shadowElevation = 5.dp,
    ) {
        Column {
            if (selectedColorTweak == null) {
                TweakOverlayActions(
                    tweaks = tweaks,
                    onMinimize = onMinimize,
                    onDrag = onDrag,
                )
                HorizontalDivider(color = TweakOverlayColors.outline)

                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(TweakOverlayLayout.fieldRowSpacing),
                ) {
                    itemsIndexed(tweaks, key = { _, tweak -> tweak.name }) { index, tweak ->
                        val section = tweak.name.substringBefore('/', missingDelimiterValue = "")
                        val previousSection = if (index == 0) {
                            null
                        } else {
                            tweaks[index - 1].name.substringBefore('/', missingDelimiterValue = "")
                        }

                        if (section.isNotEmpty() && section != previousSection) {
                            TweakOverlaySection(section)
                        }

                        TweakOverlayControl(
                            tweak = tweak,
                            onSelectColor = { selectedColorTweakName = tweak.name },
                        )
                    }
                }
            } else {
                TweakColorOverlayActions(
                    tweak = selectedColorTweak,
                    onClose = { selectedColorTweakName = null },
                    onDrag = onDrag,
                )
                HorizontalDivider(color = TweakOverlayColors.outline)
                TweakColorChooser(
                    tweak = selectedColorTweak,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun TweakOverlayActions(
    tweaks: List<SnapOTweakEntry>,
    onMinimize: () -> Unit,
    onDrag: (Float) -> Unit,
) {
    val hasChanges by remember(tweaks) {
        derivedStateOf(structuralEqualityPolicy()) {
            tweaks.any { tweak -> tweak.isChanged }
        }
    }

    TweakOverlayHeader(
        title = "Tweaks",
        hasChanges = hasChanges,
        onReset = {
            tweaks.filter { tweak -> tweak.isChanged }.forEach { tweak ->
                SnapOTweaks.reset(tweak.name)
            }
        },
        resetContentDescription = "Reset all tweaks",
        onTrailingAction = onMinimize,
        trailingIcon = R.drawable.snapo_tweaks_close,
        trailingContentDescription = "Minimize tweaks",
        onDrag = onDrag,
    )
}

@Composable
private fun TweakColorOverlayActions(
    tweak: SnapOTweakEntry,
    onClose: () -> Unit,
    onDrag: (Float) -> Unit,
) {
    val hasChanges by remember(tweak) {
        derivedStateOf(structuralEqualityPolicy()) { tweak.isChanged }
    }

    TweakOverlayHeader(
        title = tweak.name.substringAfter('/'),
        hasChanges = hasChanges,
        onReset = { SnapOTweaks.reset(tweak.name) },
        resetContentDescription = "Reset ${tweak.name}",
        onTrailingAction = onClose,
        trailingIcon = R.drawable.snapo_tweaks_check,
        trailingContentDescription = "Done editing ${tweak.name}",
        onDrag = onDrag,
    )
}

@Composable
private fun TweakOverlayHeader(
    title: String,
    hasChanges: Boolean,
    onReset: () -> Unit,
    resetContentDescription: String,
    onTrailingAction: () -> Unit,
    trailingIcon: Int,
    trailingContentDescription: String,
    onDrag: (Float) -> Unit,
) {
    val currentOnDrag by rememberUpdatedState(onDrag)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(50.dp)
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragEnd = SnapOTweakOverlaySettings::persistPositions,
                    onDragCancel = SnapOTweakOverlaySettings::persistPositions,
                ) { change, drag ->
                    change.consume()
                    currentOnDrag(drag.y)
                }
            },
    ) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(
                    start = TweakOverlayLayout.contentHorizontalPadding + 6.dp,
                    top = 2.dp,
                    end = 4.dp,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                modifier = Modifier.weight(1f),
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )

            IconButton(
                onClick = onReset,
                enabled = hasChanges,
            ) {
                Icon(
                    painter = painterResource(R.drawable.snapo_tweaks_restart),
                    contentDescription = resetContentDescription,
                )
            }

            IconButton(onClick = onTrailingAction) {
                Icon(
                    painter = painterResource(trailingIcon),
                    contentDescription = trailingContentDescription,
                )
            }
        }

        TweakOverlayDragHandle()
    }
}

@Composable
private fun BoxScope.TweakOverlayDragHandle() {
    Box(
        modifier = Modifier
            .align(Alignment.TopCenter)
            .padding(top = 7.dp)
            .width(30.dp)
            .height(3.dp)
            .background(TweakOverlayColors.secondary.copy(alpha = 0.35f), CircleShape),
    )
}

@Composable
private fun MinimizedTweakOverlay(
    onExpand: () -> Unit,
    onDrag: (Offset) -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentOnDrag by rememberUpdatedState(onDrag)

    Surface(
        onClick = onExpand,
        modifier = modifier
            .size(OverlayButtonSize)
            .systemGestureExclusion()
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragEnd = SnapOTweakOverlaySettings::persistPositions,
                    onDragCancel = SnapOTweakOverlaySettings::persistPositions,
                ) { change, drag ->
                    change.consume()
                    currentOnDrag(drag)
                }
            },
        shape = CircleShape,
        color = TweakOverlayColors.surface,
        contentColor = TweakOverlayColors.foreground,
        border = BorderStroke(1.dp, TweakOverlayColors.outline),
        shadowElevation = 4.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                painter = painterResource(R.drawable.snapo_tweaks_settings),
                contentDescription = "Open tweaks",
            )
        }
    }
}

@Composable
private fun TweakOverlaySection(
    name: String,
) {
    Text(
        text = name,
        modifier = Modifier.padding(
            start = TweakOverlayLayout.contentHorizontalPadding + 6.dp,
            top = 9.dp,
            bottom = 2.dp,
        ),
        color = TweakOverlayColors.secondary,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
    )
}

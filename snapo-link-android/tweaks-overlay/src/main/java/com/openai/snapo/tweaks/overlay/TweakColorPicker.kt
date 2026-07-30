package com.openai.snapo.tweaks.overlay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openai.snapo.tweaks.SnapOTweakEntry
import com.openai.snapo.tweaks.SnapOTweakValue
import com.openai.snapo.tweaks.SnapOTweaks
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

private val DefaultPickerColor = PickerColor(
    hue = 210f,
    saturation = 0.75f,
    brightness = 1f,
    alpha = 1f,
)

/** HSV state used by the visual picker. Values are clamped when converted to a Compose color. */
internal data class PickerColor(
    val hue: Float,
    val saturation: Float,
    val brightness: Float,
    val alpha: Float,
)

internal class ColorPickerState(initialColor: PickerColor) {
    var color by mutableStateOf(initialColor)
        private set

    private var locallyEmittedColor: Color? = null

    fun sync(source: Color) {
        if (source != locallyEmittedColor) {
            color = source.toPickerColorOrNull() ?: DefaultPickerColor
        }
        locallyEmittedColor = null
    }

    fun select(
        selected: PickerColor,
        onColorChange: (Color) -> Unit,
    ) {
        color = selected
        emit(selected.toComposeColor(), onColorChange)
    }

    fun selectAlpha(
        alpha: Float,
        source: Color,
        onColorChange: (Color) -> Unit,
    ) {
        val selected = color.copy(alpha = alpha)
        color = selected
        val updated = if (source.isSpecified) {
            source.copy(alpha = alpha.coerceIn(0f, 1f))
        } else {
            selected.toComposeColor()
        }
        emit(updated, onColorChange)
    }

    private fun emit(
        updated: Color,
        onColorChange: (Color) -> Unit,
    ) {
        locallyEmittedColor = updated
        onColorChange(updated)
    }
}

@Composable
private fun rememberColorPickerState(
    name: String,
    source: Color,
): ColorPickerState {
    val state = remember(name) {
        ColorPickerState(source.toPickerColorOrNull() ?: DefaultPickerColor)
    }

    LaunchedEffect(source) {
        state.sync(source)
    }

    return state
}

@Composable
internal fun TweakColorField(
    tweak: SnapOTweakEntry,
    onClick: () -> Unit,
) {
    val color = (tweak.value.value as SnapOTweakValue.ColorValue).value
    val label = color.toPickerLabel()

    Row(
        modifier = Modifier
            .height(48.dp)
            .clickable(
                role = Role.Button,
                onClick = onClick,
            )
            .semantics {
                contentDescription = "Choose color for ${tweak.name}. Current value: $label"
            }
            .padding(start = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = label,
            color = TweakOverlayColors.secondary,
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
        )
        TweakColorSwatch(
            color = color,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
internal fun TweakColorChooser(
    tweak: SnapOTweakEntry,
    modifier: Modifier = Modifier,
) {
    val color = (tweak.value.value as SnapOTweakValue.ColorValue).value
    val pickerState = rememberColorPickerState(tweak.name, color)
    val updateColor: (Color) -> Unit = { updated ->
        SnapOTweaks.update(
            tweak.name,
            SnapOTweakValue.ColorValue(updated),
        )
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = TweakOverlayLayout.contentHorizontalPadding, vertical = 4.dp),
    ) {
        TweakColorPreview(color)
        HueChannel(pickerState.color) { selected -> pickerState.select(selected, updateColor) }
        SaturationChannel(pickerState.color) { selected ->
            pickerState.select(selected, updateColor)
        }
        BrightnessChannel(pickerState.color) { selected ->
            pickerState.select(selected, updateColor)
        }
        OpacityChannel(pickerState.color) { alpha ->
            pickerState.selectAlpha(alpha, color, updateColor)
        }
    }
}

@Composable
private fun HueChannel(
    color: PickerColor,
    onColorChange: (PickerColor) -> Unit,
) {
    ColorChannelRow(
        label = "Hue",
        value = color.hue,
        valueRange = 0f..360f,
        trackColors = listOf(
            Color.Red,
            Color.Yellow,
            Color.Green,
            Color.Cyan,
            Color.Blue,
            Color.Magenta,
            Color.Red,
        ),
        thumbColor = color.copy(alpha = 1f).toComposeColor(),
        onValueChange = { hue -> onColorChange(color.copy(hue = hue)) },
    )
}

@Composable
private fun SaturationChannel(
    color: PickerColor,
    onColorChange: (PickerColor) -> Unit,
) {
    ColorChannelRow(
        label = "Saturation",
        value = color.saturation,
        valueRange = 0f..1f,
        trackColors = listOf(
            color.copy(saturation = 0f, alpha = 1f).toComposeColor(),
            color.copy(saturation = 1f, alpha = 1f).toComposeColor(),
        ),
        thumbColor = color.copy(alpha = 1f).toComposeColor(),
        onValueChange = { saturation ->
            onColorChange(color.copy(saturation = saturation))
        },
    )
}

@Composable
private fun BrightnessChannel(
    color: PickerColor,
    onColorChange: (PickerColor) -> Unit,
) {
    ColorChannelRow(
        label = "Brightness",
        value = color.brightness,
        valueRange = 0f..1f,
        trackColors = listOf(
            Color.Black,
            color.copy(brightness = 1f, alpha = 1f).toComposeColor(),
        ),
        thumbColor = color.copy(alpha = 1f).toComposeColor(),
        onValueChange = { brightness ->
            onColorChange(color.copy(brightness = brightness))
        },
    )
}

@Composable
private fun OpacityChannel(
    color: PickerColor,
    onAlphaChange: (Float) -> Unit,
) {
    ColorChannelRow(
        label = "Opacity",
        value = color.alpha,
        valueRange = 0f..1f,
        trackColors = listOf(
            color.copy(alpha = 0f).toComposeColor(),
            color.copy(alpha = 1f).toComposeColor(),
        ),
        thumbColor = color.toComposeColor(),
        showCheckerboard = true,
        onValueChange = onAlphaChange,
    )
}

@Composable
private fun TweakColorPreview(
    color: Color,
) {
    val label = color.toPickerLabel()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        TweakColorSwatch(
            color = color,
            modifier = Modifier
                .size(34.dp)
                .semantics { contentDescription = "Current color: $label" },
        )
        Column {
            Text(
                text = label,
                color = TweakOverlayColors.foreground,
                fontSize = 13.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = if (color.isSpecified) "Live preview" else "No color selected",
                color = TweakOverlayColors.secondary,
                fontSize = 11.sp,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun ColorChannelRow(
    label: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    trackColors: List<Color>,
    thumbColor: Color,
    onValueChange: (Float) -> Unit,
    showCheckerboard: Boolean = false,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .padding(horizontal = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            modifier = Modifier.width(72.dp),
            color = TweakOverlayColors.secondary,
            fontSize = 11.sp,
            maxLines = 1,
        )
        ColorGradientSlider(
            label = label,
            value = value,
            valueRange = valueRange,
            trackColors = trackColors,
            thumbColor = thumbColor,
            showCheckerboard = showCheckerboard,
            onValueChange = onValueChange,
            modifier = Modifier.weight(1f),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ColorGradientSlider(
    label: String,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    trackColors: List<Color>,
    thumbColor: Color,
    showCheckerboard: Boolean,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val colors = SliderDefaults.colors(
        thumbColor = thumbColor,
        activeTrackColor = Color.Transparent,
        inactiveTrackColor = Color.Transparent,
    )

    Slider(
        value = value.coerceIn(valueRange),
        onValueChange = onValueChange,
        modifier = modifier.semantics { contentDescription = "$label color channel" },
        valueRange = valueRange,
        colors = colors,
        interactionSource = interactionSource,
        thumb = {
            Box(
                modifier = Modifier
                    .size(14.dp)
                    .background(thumbColor.copy(alpha = 1f), CircleShape)
                    .border(2.dp, TweakOverlayColors.surface, CircleShape),
            )
        },
        track = {
            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(10.dp)
                    .clip(RoundedCornerShape(5.dp)),
            ) {
                if (showCheckerboard) {
                    drawCheckerboard()
                }
                drawRect(brush = Brush.horizontalGradient(trackColors))
                drawRoundRect(
                    color = TweakOverlayColors.outline,
                    cornerRadius = CornerRadius(5.dp.toPx(), 5.dp.toPx()),
                    style = Stroke(width = 1.dp.toPx()),
                )
            }
        },
    )
}

@Composable
private fun TweakColorSwatch(
    color: Color,
    modifier: Modifier = Modifier,
) {
    Canvas(
        modifier = modifier
            .clip(RoundedCornerShape(4.dp))
            .border(1.dp, TweakOverlayColors.outline, RoundedCornerShape(4.dp)),
    ) {
        drawCheckerboard()
        if (color.isSpecified) {
            drawRect(color = color)
        } else {
            drawLine(
                color = TweakOverlayColors.secondary,
                start = Offset(2.dp.toPx(), size.height - 2.dp.toPx()),
                end = Offset(size.width - 2.dp.toPx(), 2.dp.toPx()),
                strokeWidth = 1.5.dp.toPx(),
            )
        }
    }
}

private fun DrawScope.drawCheckerboard() {
    val cellSize = 6.dp.toPx()
    val columns = ceil(size.width / cellSize).toInt()
    val rows = ceil(size.height / cellSize).toInt()

    for (row in 0..rows) {
        for (column in 0..columns) {
            val color = if ((row + column) % 2 == 0) {
                Color.White
            } else {
                Color(0xFFD9DDE3)
            }
            val x = column * cellSize
            val y = row * cellSize
            drawRect(
                color = color,
                topLeft = Offset(x, y),
                size = Size(
                    width = min(cellSize, size.width - x).coerceAtLeast(0f),
                    height = min(cellSize, size.height - y).coerceAtLeast(0f),
                ),
            )
        }
    }
}

internal fun Color.toPickerColorOrNull(): PickerColor? {
    if (!isSpecified) return null

    val srgb = runCatching { convert(ColorSpaces.Srgb) }.getOrNull() ?: return null
    val red = srgb.red.coerceIn(0f, 1f)
    val green = srgb.green.coerceIn(0f, 1f)
    val blue = srgb.blue.coerceIn(0f, 1f)
    val maximum = max(red, max(green, blue))
    val minimum = min(red, min(green, blue))
    val delta = maximum - minimum
    val hue = when {
        delta == 0f -> 0f
        maximum == red -> 60f * (((green - blue) / delta) % 6f)
        maximum == green -> 60f * ((blue - red) / delta + 2f)
        else -> 60f * ((red - green) / delta + 4f)
    }.let { computed -> if (computed < 0f) computed + 360f else computed }
    val saturation = if (maximum == 0f) 0f else delta / maximum

    return PickerColor(
        hue = hue,
        saturation = saturation,
        brightness = maximum,
        alpha = alpha.coerceIn(0f, 1f),
    )
}

internal fun PickerColor.toComposeColor(): Color =
    Color.hsv(
        hue = ((hue % 360f) + 360f) % 360f,
        saturation = saturation.coerceIn(0f, 1f),
        value = brightness.coerceIn(0f, 1f),
        alpha = alpha.coerceIn(0f, 1f),
    )

internal fun Color.toPickerLabel(): String {
    if (!isSpecified) return "Unspecified"

    val argb = runCatching { toArgb() }.getOrNull() ?: return "Unsupported"
    val rgb = (argb and 0x00FF_FFFF)
        .toString(radix = 16)
        .padStart(length = 6, padChar = '0')
        .uppercase()
    val alpha = argb ushr 24

    return if (alpha == 0xFF) {
        "#$rgb"
    } else {
        val suffix = alpha.toString(radix = 16).padStart(length = 2, padChar = '0').uppercase()
        "#$rgb$suffix"
    }
}

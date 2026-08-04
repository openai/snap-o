package com.openai.snapo.tweaks.overlay

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.structuralEqualityPolicy
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openai.snapo.tweaks.SnapOTweakEntry
import com.openai.snapo.tweaks.SnapOTweakValue
import com.openai.snapo.tweaks.SnapOTweaks
import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.pow
import kotlin.math.round
import kotlin.math.roundToLong

private const val MaximumDiscreteSliderIntervals = 1_000

@Composable
internal fun TweakOverlayControl(
    tweak: SnapOTweakEntry,
    onSelectColor: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = TweakOverlayLayout.contentHorizontalPadding),
    ) {
        when (val defaultValue = tweak.defaultValue) {
            is SnapOTweakValue.Integer -> if (defaultValue.hasSliderBounds()) {
                TweakNumericControl(tweak) { modifier ->
                    TweakIntegerSlider(tweak, defaultValue, modifier)
                }
            } else {
                TweakOverlayLabelRow(tweak) {
                    TweakIntegerEditor(tweak, defaultValue)
                }
            }
            is SnapOTweakValue.Floating -> if (defaultValue.hasSliderBounds()) {
                TweakNumericControl(tweak) { modifier ->
                    TweakFloatingSlider(tweak, defaultValue, modifier)
                }
            } else {
                TweakOverlayLabelRow(tweak) {
                    TweakFloatingEditor(tweak, defaultValue)
                }
            }
            is SnapOTweakValue.Text -> {
                TweakOverlayLabelRow(tweak) {}
                TweakTextEditor(tweak)
            }
            is SnapOTweakValue.Toggle -> TweakOverlayLabelRow(tweak) {
                TweakToggleField(tweak)
            }
            is SnapOTweakValue.Selection -> TweakOverlayLabelRow(tweak) {
                TweakSelectionField(tweak)
            }
            is SnapOTweakValue.ColorValue -> TweakOverlayLabelRow(tweak) {
                TweakColorField(tweak, onSelectColor)
            }
            is SnapOTweakValue.Action -> TweakOverlayLabelRow(tweak) {
                val action = tweak.value.value as SnapOTweakValue.Action
                TextButton(
                    onClick = { SnapOTweaks.invokeAction(tweak.name) },
                    enabled = !action.conflicted,
                ) {
                    Text(if (action.conflicted) "Conflict" else "Run")
                }
            }
        }
    }
}

private fun SnapOTweakValue.Integer.hasSliderBounds(): Boolean {
    val minimum = min ?: return false
    val maximum = max ?: return false

    return hasRepresentableIntegerSliderBounds(minimum, maximum, step)
}

@Composable
private fun SnapOTweakValue.Floating.hasSliderBounds(): Boolean = remember(min, max, step) {
    val minimum = min ?: return@remember false
    val maximum = max ?: return@remember false

    hasRepresentableFloatingSliderBounds(minimum, maximum, step)
}

internal fun hasRepresentableIntegerSliderBounds(
    min: Int,
    max: Int,
    step: Int,
): Boolean {
    val increment = step.coerceAtLeast(1)
    val intervals = (max.toLong() - min.toLong()) / increment
    if (intervals < 1) return false

    val effectiveMaximum = (min.toLong() + intervals * increment).toInt()
    val firstStep = (min.toLong() + increment).toInt()
    val largestMagnitude = maxOf(abs(min.toLong()), abs(effectiveMaximum.toLong()))

    return min.isExactlyRepresentableAsFloat() &&
        firstStep.isExactlyRepresentableAsFloat() &&
        effectiveMaximum.isExactlyRepresentableAsFloat() &&
        increment.toDouble() >= Math.ulp(largestMagnitude.toFloat()).toDouble()
}

private fun Int.isExactlyRepresentableAsFloat(): Boolean =
    toFloat().toDouble() == toDouble()

internal fun hasRepresentableFloatingSliderBounds(
    min: Float,
    max: Float,
    step: Float?,
): Boolean {
    if (max <= min) return false
    val increment = step ?: return true
    if (min.toDouble() + increment.toDouble() > max.toDouble()) return false

    val largestMagnitude = maxOf(abs(min), abs(max))
    if (increment < Math.ulp(largestMagnitude)) return false

    val snapper = FloatingSliderSnapper(min, max, increment)
    val firstValue = snapper.snap((min.toDouble() + increment.toDouble()).toFloat())

    return isValidFloatingEditorValue(firstValue, min, max, increment, min) &&
        isValidFloatingEditorValue(snapper.effectiveMaximum, min, max, increment, min)
}

@Composable
private fun TweakNumericControl(
    tweak: SnapOTweakEntry,
    slider: @Composable (Modifier) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = TweakOverlayLayout.sliderRowHeight),
        verticalArrangement = Arrangement.spacedBy(
            (TweakOverlayLayout.sliderLabelSpacing - 36.dp).coerceIn(-24.dp, 0.dp),
        ),
    ) {
        TweakOverlayLabelRow(
            tweak = tweak,
            compact = true,
        ) {
            TweakNumericFieldValue(tweak)
        }
        slider(
            Modifier.requiredHeight(48.dp),
        )
    }
}

@Composable
private fun TweakOverlayLabelRow(
    tweak: SnapOTweakEntry,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
    field: @Composable () -> Unit,
) {
    val rowHeight = if (compact) 20.dp else 48.dp
    val isChanged by remember(tweak) {
        derivedStateOf(structuralEqualityPolicy()) { tweak.isChanged }
    }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 6.dp)
            .heightIn(min = rowHeight),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = tweak.name.substringAfter('/'),
                modifier = Modifier.weight(1f, fill = false),
                color = TweakOverlayColors.foreground,
                fontSize = 13.sp,
            )

            if (isChanged) {
                val spacing = TweakOverlayLayout.resetButtonSpacing

                Box(
                    modifier = Modifier
                        .width(24.dp + spacing)
                        .height(rowHeight),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    IconButton(
                        onClick = { SnapOTweaks.update(tweak.name, tweak.defaultValue) },
                        modifier = Modifier
                            .size(48.dp)
                            .offset(x = spacing - 12.dp),
                    ) {
                        Icon(
                            painter = painterResource(R.drawable.snapo_tweaks_restart),
                            contentDescription = "Reset ${tweak.name}",
                            modifier = Modifier.size(16.dp),
                            tint = TweakOverlayColors.secondary,
                        )
                    }
                }
            }
        }

        Box(
            contentAlignment = Alignment.CenterEnd,
        ) {
            field()
        }
    }
}

@Composable
private fun TweakNumericFieldValue(tweak: SnapOTweakEntry) {
    val value = when (val currentValue = tweak.value.value) {
        is SnapOTweakValue.Integer -> currentValue.value.toString()
        is SnapOTweakValue.Floating -> currentValue.value.toString()
        else -> return
    }

    TweakFieldText(value)
}

@Composable
private fun TweakToggleField(tweak: SnapOTweakEntry) {
    val value = tweak.value.value as SnapOTweakValue.Toggle

    Checkbox(
        checked = value.value,
        onCheckedChange = { checked ->
            SnapOTweaks.update(tweak.name, value.copy(value = checked))
        },
        colors = CheckboxDefaults.colors(
            checkedColor = TweakOverlayColors.foreground,
            uncheckedColor = TweakOverlayColors.secondary,
        ),
    )
}

@Composable
private fun TweakSelectionField(tweak: SnapOTweakEntry) {
    val selection = tweak.value.value as SnapOTweakValue.Selection
    var expanded by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                .clickable(
                    role = Role.Button,
                    onClick = { expanded = true },
                )
                .semantics {
                    contentDescription = "Choose option for ${tweak.name}. Current value: ${selection.value}"
                }
                .padding(start = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            TweakFieldText(selection.value)
            Text(text = "▾", color = TweakOverlayColors.secondary, fontSize = 11.sp)
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(TweakOverlayColors.surface),
        ) {
            selection.options.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = option,
                            color = TweakOverlayColors.foreground,
                            fontSize = 13.sp,
                        )
                    },
                    onClick = {
                        expanded = false
                        SnapOTweaks.update(tweak.name, selection.copy(value = option))
                    },
                    trailingIcon = if (option == selection.value) {
                        {
                            Icon(
                                painter = painterResource(R.drawable.snapo_tweaks_check),
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                                tint = TweakOverlayColors.foreground,
                            )
                        }
                    } else {
                        null
                    },
                )
            }
        }
    }
}

@Composable
private fun TweakIntegerEditor(
    tweak: SnapOTweakEntry,
    defaultValue: SnapOTweakValue.Integer,
) {
    val value = tweak.value.value as SnapOTweakValue.Integer
    val origin = defaultValue.min ?: defaultValue.value

    TweakNumericEditor(
        committed = value.value.toString(),
        keyboardType = numericKeyboardType(defaultValue.min),
    ) { updated ->
        val parsed = updated.toIntOrNull() ?: return@TweakNumericEditor
        val isValid = isValidIntegerEditorValue(
            value = parsed,
            min = defaultValue.min,
            max = defaultValue.max,
            step = defaultValue.step,
            origin = origin,
        )
        if (!isValid) {
            return@TweakNumericEditor
        }

        SnapOTweaks.update(tweak.name, value.copy(value = parsed))
    }
}

@Composable
private fun TweakFloatingEditor(
    tweak: SnapOTweakEntry,
    defaultValue: SnapOTweakValue.Floating,
) {
    val value = tweak.value.value as SnapOTweakValue.Floating
    val origin = defaultValue.min ?: defaultValue.value

    TweakNumericEditor(
        committed = value.value.toString(),
        keyboardType = numericKeyboardType(defaultValue.min),
    ) { updated ->
        val parsed = updated.toFloatOrNull() ?: return@TweakNumericEditor
        val isValid = isValidFloatingEditorValue(
            value = parsed,
            min = defaultValue.min,
            max = defaultValue.max,
            step = defaultValue.step,
            origin = origin,
        )
        if (!isValid) {
            return@TweakNumericEditor
        }

        SnapOTweaks.update(tweak.name, value.copy(value = parsed))
    }
}

internal fun numericKeyboardType(minimum: Number?): KeyboardType =
    if (minimum == null || minimum.toDouble() < 0.0) {
        KeyboardType.Text
    } else {
        KeyboardType.Decimal
    }

@Composable
private fun TweakNumericEditor(
    committed: String,
    keyboardType: KeyboardType,
    onValueChange: (String) -> Unit,
) {
    var draft by rememberSaveable { mutableStateOf(committed) }
    var isFocused by remember { mutableStateOf(false) }

    LaunchedEffect(committed, isFocused) {
        if (!isFocused) draft = committed
    }

    BasicTextField(
        value = draft,
        onValueChange = { updated ->
            draft = updated
            onValueChange(updated)
        },
        modifier = Modifier
            .width(84.dp)
            .onFocusChanged { isFocused = it.isFocused },
        textStyle = TextStyle(
            color = TweakOverlayColors.foreground,
            fontSize = 13.sp,
            textAlign = TextAlign.End,
        ),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        singleLine = true,
    )
}

@Composable
private fun TweakIntegerSlider(
    tweak: SnapOTweakEntry,
    defaultValue: SnapOTweakValue.Integer,
    modifier: Modifier = Modifier,
) {
    val min = defaultValue.min ?: return
    val max = defaultValue.max ?: return
    if (max <= min) return
    val snapper = remember(min, max, defaultValue.step) {
        IntegerSliderSnapper(min, max, defaultValue.step)
    }
    val value = tweak.value.value as SnapOTweakValue.Integer

    TweakCompactSlider(
        value = value.value.toFloat().coerceIn(min.toFloat(), snapper.effectiveMaximum.toFloat()),
        onValueChange = { updated ->
            SnapOTweaks.update(tweak.name, value.copy(value = snapper.snap(updated)))
        },
        valueRange = min.toFloat()..snapper.effectiveMaximum.toFloat(),
        steps = snapper.materialSteps,
        modifier = modifier,
    )
}

@Composable
private fun TweakFloatingSlider(
    tweak: SnapOTweakEntry,
    defaultValue: SnapOTweakValue.Floating,
    modifier: Modifier = Modifier,
) {
    val min = defaultValue.min ?: return
    val max = defaultValue.max ?: return
    if (max <= min) return

    val snapper = remember(min, max, defaultValue.step) {
        FloatingSliderSnapper(min, max, defaultValue.step)
    }
    val value = tweak.value.value as SnapOTweakValue.Floating

    TweakCompactSlider(
        value = value.value.coerceIn(min, snapper.effectiveMaximum),
        onValueChange = { updated ->
            val snapped = snapper.snap(updated)
            SnapOTweaks.update(tweak.name, value.copy(value = snapped))
        },
        valueRange = min..snapper.effectiveMaximum,
        steps = snapper.materialSteps,
        modifier = modifier,
    )
}

internal class IntegerSliderSnapper(
    private val min: Int,
    max: Int,
    step: Int,
) {
    private val increment = step.coerceAtLeast(1)
    private val maximumStep = (max.toLong() - min.toLong()) / increment

    val effectiveMaximum: Int = (min.toLong() + maximumStep * increment).toInt()
    val materialSteps: Int = if (maximumStep <= MaximumDiscreteSliderIntervals) {
        (maximumStep - 1).coerceAtLeast(0).toInt()
    } else {
        0
    }

    fun snap(value: Float): Int {
        val boundedValue = value.coerceIn(min.toFloat(), effectiveMaximum.toFloat())
        val selectedStep = ((boundedValue.toDouble() - min.toDouble()) / increment)
            .roundToLong()
            .coerceIn(0L, maximumStep)

        return (min.toLong() + selectedStep * increment).toInt()
    }
}

internal fun snapFloatingSliderValue(
    value: Float,
    min: Float,
    max: Float,
    step: Float?,
): Float = FloatingSliderSnapper(min, max, step).snap(value)

internal class FloatingSliderSnapper(
    private val min: Float,
    private val max: Float,
    step: Float?,
) {
    private val increment = step?.takeIf { it > 0f }
    private val minimumDecimal = BigDecimal(min.toString())
    private val incrementDecimal = increment?.let { BigDecimal(it.toString()) }
    private val scale = maxOf(minimumDecimal.scale(), incrementDecimal?.scale() ?: 0)
    private val multiplier = 10.0.pow(scale)
    private val maximumStepDecimal = incrementDecimal?.let { decimalIncrement ->
        BigDecimal(max.toString())
            .subtract(minimumDecimal)
            .divide(decimalIncrement, 0, RoundingMode.FLOOR)
    }
    private val maximumStep = maximumStepDecimal?.toDouble()

    val effectiveMaximum: Float = if (incrementDecimal != null && maximumStepDecimal != null) {
        minimumDecimal.add(incrementDecimal.multiply(maximumStepDecimal)).toFloat()
    } else {
        max
    }

    val materialSteps: Int
        get() = if (maximumStep != null && maximumStep <= MaximumDiscreteSliderIntervals) {
            (maximumStep.toInt() - 1).coerceAtLeast(0)
        } else {
            0
        }

    fun snap(value: Float): Float {
        val boundedValue = value.coerceIn(min, effectiveMaximum)
        val step = increment ?: return boundedValue
        val selectedStep = floor(
            (boundedValue.toDouble() - min.toDouble()) / step.toDouble() + 0.5,
        )
            .coerceIn(0.0, requireNotNull(maximumStep))

        return valueAt(selectedStep)
    }

    private fun valueAt(step: Double): Float {
        val snapped = min.toDouble() + requireNotNull(increment).toDouble() * step

        return (round(snapped * multiplier) / multiplier).toFloat()
    }
}

internal fun isValidIntegerEditorValue(
    value: Int,
    min: Int?,
    max: Int?,
    step: Int,
    origin: Int,
): Boolean =
    (min == null || value >= min) &&
        (max == null || value <= max) &&
        (value.toLong() - origin.toLong()) % step.coerceAtLeast(1) == 0L

internal fun isValidFloatingEditorValue(
    value: Float,
    min: Float?,
    max: Float?,
    step: Float?,
    origin: Float,
): Boolean {
    if (!value.isFinite()) return false
    if (min != null && value < min) return false
    if (max != null && value > max) return false

    val increment = step?.takeIf { it > 0f } ?: return true
    val selectedValue = BigDecimal(value.toString())
    val decimalOrigin = BigDecimal(origin.toString())
    val decimalStep = BigDecimal(increment.toString())

    return selectedValue.subtract(decimalOrigin).remainder(decimalStep)
        .compareTo(BigDecimal.ZERO) == 0
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TweakCompactSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    steps: Int,
    modifier: Modifier = Modifier,
) {
    val colors = SliderDefaults.colors(
        thumbColor = TweakOverlayColors.foreground,
        activeTrackColor = TweakOverlayColors.foreground,
        inactiveTrackColor = TweakOverlayColors.outline,
    )
    val interactionSource = remember { MutableInteractionSource() }

    Slider(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        valueRange = valueRange,
        steps = steps,
        colors = colors,
        interactionSource = interactionSource,
        thumb = {
            SliderDefaults.Thumb(
                interactionSource = interactionSource,
                colors = colors,
                thumbSize = DpSize(12.dp, 12.dp),
            )
        },
        track = { state ->
            SliderDefaults.Track(
                sliderState = state,
                modifier = Modifier.height(2.dp),
                colors = colors,
                drawStopIndicator = null,
                drawTick = { _, _ -> },
                thumbTrackGapSize = 0.dp,
                trackInsideCornerSize = 0.dp,
            )
        },
    )
}

@Composable
private fun TweakTextEditor(
    tweak: SnapOTweakEntry,
) {
    val value = tweak.value.value as SnapOTweakValue.Text

    BasicTextField(
        value = value.value,
        onValueChange = { updated ->
            SnapOTweaks.update(tweak.name, value.copy(value = updated))
        },
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 7.dp)
            .background(TweakOverlayColors.field, RoundedCornerShape(5.dp))
            .padding(horizontal = 10.dp, vertical = 10.dp),
        textStyle = TextStyle(
            color = TweakOverlayColors.foreground,
            fontSize = 13.sp,
        ),
        singleLine = true,
    )
}

@Composable
private fun TweakFieldText(value: String) {
    Text(
        text = value,
        color = TweakOverlayColors.foreground,
        fontSize = 13.sp,
    )
}

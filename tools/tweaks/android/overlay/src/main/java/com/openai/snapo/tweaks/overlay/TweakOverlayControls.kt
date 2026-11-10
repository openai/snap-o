package com.openai.snapo.tweaks.overlay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.structuralEqualityPolicy
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.lerp
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.offset
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
import kotlin.math.roundToInt
import kotlin.math.roundToLong

private const val MaximumDiscreteSliderIntervals = 1_000
private val ControlHorizontalPadding = 6.dp
private val InlineFieldSpacing = 4.dp
private val MinimumInlineLabelWidth = 72.dp
private val MinimumSliderTrackWidth = 96.dp
private val SliderTrackHeight = 12.dp
private val NumericEditorWidth = 84.dp

@Composable
internal fun TweakOverlayControl(
    tweak: SnapOTweakEntry,
    onSelectColor: () -> Unit,
    onSelectCurve: () -> Unit = {},
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = TweakOverlayLayout.contentHorizontalPadding),
    ) {
        when (val defaultValue = tweak.defaultValue) {
            is SnapOTweakValue.Integer -> if (defaultValue.hasSliderBounds()) {
                TweakNumericControl(
                    tweak = tweak,
                    slider = { TweakIntegerSlider(tweak, defaultValue, it) },
                    editor = { TweakIntegerEditor(tweak, defaultValue, it) },
                )
            } else {
                TweakOverlayLabelRow(tweak) {
                    TweakIntegerEditor(tweak, defaultValue, Modifier.width(NumericEditorWidth))
                }
            }
            is SnapOTweakValue.Floating -> if (defaultValue.hasSliderBounds()) {
                TweakNumericControl(
                    tweak = tweak,
                    slider = { TweakFloatingSlider(tweak, defaultValue, it) },
                    editor = { TweakFloatingEditor(tweak, defaultValue, it) },
                )
            } else {
                TweakOverlayLabelRow(tweak) {
                    TweakFloatingEditor(tweak, defaultValue, Modifier.width(NumericEditorWidth))
                }
            }
            is SnapOTweakValue.Text -> TweakInlineFieldRow(tweak) { modifier ->
                TweakTextEditor(tweak, modifier)
            }
            is SnapOTweakValue.Toggle -> TweakOverlayLabelRow(tweak) {
                TweakToggleField(tweak)
            }
            is SnapOTweakValue.Selection -> TweakOverlayLabelRow(tweak) {
                TweakSelectionField(tweak)
            }
            is SnapOTweakValue.Curve -> TweakOverlayLabelRow(tweak) {
                TweakBezierField(tweak, onSelectCurve)
            }
            is SnapOTweakValue.ColorValue -> TweakOverlayLabelRow(tweak) {
                TweakColorField(tweak, onSelectColor)
            }
            is SnapOTweakValue.Action -> TweakOverlayLabelRow(tweak) {
                TweakActionField(tweak)
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
    editor: @Composable (Modifier) -> Unit,
) {
    val colors = TweakOverlayColors.current
    var editingNumber by remember { mutableStateOf(false) }
    val editorWidth = if (editingNumber) NumericEditorWidth else 52.dp
    val minimumFieldWidth = with(LocalDensity.current) {
        val sliderWidth = MinimumSliderTrackWidth.roundToPx() + 2 * ControlHorizontalPadding.roundToPx()
        (sliderWidth + InlineFieldSpacing.roundToPx() + editorWidth.roundToPx()).toDp()
    }
    TweakInlineFieldRow(tweak, reservedFieldWidth = minimumFieldWidth) { modifier ->
        Row(
            modifier = modifier,
            horizontalArrangement = Arrangement.spacedBy(InlineFieldSpacing),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            slider(Modifier.weight(1f).semantics { contentDescription = tweak.name })
            editor(
                Modifier
                    .width(editorWidth)
                    .heightIn(min = TweakOverlayLayout.fieldRowHeight)
                    .onFocusChanged { editingNumber = it.isFocused }
                    .semantics { contentDescription = "Edit ${tweak.name}" }
                    .wrapContentHeight()
                    .background(colors.field, RoundedCornerShape(5.dp))
                    .padding(horizontal = 6.dp, vertical = 5.dp),
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TweakInlineFieldRow(
    tweak: SnapOTweakEntry,
    reservedFieldWidth: Dp? = null,
    field: @Composable (Modifier) -> Unit,
) {
    FlowRow(
        modifier = Modifier.fillMaxWidth().padding(horizontal = ControlHorizontalPadding),
        horizontalArrangement = Arrangement.spacedBy(InlineFieldSpacing),
        itemVerticalAlignment = Alignment.CenterVertically,
    ) {
        val labelModifier = if (reservedFieldWidth == null) {
            Modifier.weight(1f).widthIn(min = MinimumInlineLabelWidth)
        } else {
            Modifier.layout { measurable, constraints ->
                val inlineWidth = constraints.maxWidth - reservedFieldWidth.roundToPx() - InlineFieldSpacing.roundToPx()
                // Let FlowRow place the controls below the label when an inline label would be too narrow.
                val labelConstraints = if (inlineWidth >= MinimumInlineLabelWidth.roundToPx()) {
                    constraints.copy(maxWidth = inlineWidth)
                } else {
                    constraints
                }
                val label = measurable.measure(labelConstraints)
                layout(label.width, label.height) { label.placeRelative(0, 0) }
            }
        }
        TweakOverlayLabel(
            tweak = tweak,
            resetButtonHeight = 20.dp,
            modifier = labelModifier,
            reserveResetSpace = true,
        )
        // FlowRow uses the field's intrinsic width to decide when it needs its own line.
        field(Modifier.weight(2f).width(reservedFieldWidth ?: 152.dp))
    }
}

@Composable
private fun TweakOverlayLabelRow(
    tweak: SnapOTweakEntry,
    field: @Composable () -> Unit,
) {
    Layout(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = ControlHorizontalPadding)
            .heightIn(min = TweakOverlayLayout.fieldRowHeight),
        content = {
            TweakOverlayLabel(tweak, TweakOverlayLayout.fieldRowHeight)
            Box(contentAlignment = Alignment.CenterEnd) { field() }
        },
    ) { (label, control), constraints ->
        val gap = 8.dp.roundToPx()
        val available = constraints.copy(minWidth = 0, minHeight = 0).offset(horizontal = -gap)
        // Reserve up to 40% for the label. A compact control gives the label the remaining space.
        val preferredLabelWidth = label.maxIntrinsicWidth(available.maxHeight)
        val labelReserve = minOf(preferredLabelWidth, (available.maxWidth * 0.4f).roundToInt())
        val measuredControl = control.measure(available.offset(horizontal = -labelReserve))
        val measuredLabel = label.measure(available.offset(horizontal = -measuredControl.width))
        val width = constraints.constrainWidth(measuredLabel.width + gap + measuredControl.width)
        val height = constraints.constrainHeight(maxOf(measuredLabel.height, measuredControl.height))
        layout(width, height) {
            measuredLabel.placeRelative(0, (height - measuredLabel.height) / 2)
            measuredControl.placeRelative(width - measuredControl.width, (height - measuredControl.height) / 2)
        }
    }
}

@Composable
private fun TweakOverlayLabel(
    tweak: SnapOTweakEntry,
    resetButtonHeight: Dp,
    modifier: Modifier = Modifier,
    reserveResetSpace: Boolean = false,
) {
    val colors = TweakOverlayColors.current
    val isChanged by remember(tweak) {
        derivedStateOf(structuralEqualityPolicy()) { tweak.isChanged }
    }
    val emptyResetSlot = reserveResetSpace && !isChanged
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = tweak.name.substringAfter('/'),
            modifier = if (emptyResetSlot) Modifier else Modifier.weight(1f, fill = false),
            color = colors.foreground,
            fontSize = 13.sp,
            lineHeight = 16.sp,
        )
        if (isChanged || reserveResetSpace) {
            val slotWidth = if (reserveResetSpace) 24.dp else 24.dp + TweakOverlayLayout.resetButtonSpacing
            // Measure the text first while the reset slot is empty. The slot takes only the space left over.
            val slotModifier = if (emptyResetSlot) Modifier.weight(1f, fill = false) else Modifier
            Box(
                modifier = slotModifier.width(slotWidth).height(resetButtonHeight),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (isChanged) {
                    IconButton(
                        onClick = { SnapOTweaks.reset(tweak.name) },
                        modifier = Modifier.size(width = 24.dp, height = 48.dp),
                    ) {
                        Icon(
                            painter = painterResource(R.drawable.snapo_tweaks_restart),
                            contentDescription = "Reset ${tweak.name}",
                            modifier = Modifier.size(16.dp),
                            tint = colors.secondary,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TweakToggleField(tweak: SnapOTweakEntry) {
    val colors = TweakOverlayColors.current
    val value = tweak.value.value as SnapOTweakValue.Toggle
    val interactionSource = remember { MutableInteractionSource() }

    Box(
        modifier = Modifier
            .size(width = 48.dp, height = TweakOverlayLayout.fieldRowHeight)
            .toggleable(
                value = value.value,
                interactionSource = interactionSource,
                indication = null,
                role = Role.Checkbox,
            ) { checked ->
                SnapOTweaks.update(tweak.name, value.copy(value = checked))
            }
            .semantics { contentDescription = tweak.name.substringAfter('/') },
        contentAlignment = Alignment.CenterEnd,
    ) {
        Checkbox(
            checked = value.value,
            onCheckedChange = null,
            modifier = Modifier.size(20.dp).indication(interactionSource, ripple(bounded = false, radius = 20.dp)),
            colors = CheckboxDefaults.colors(
                checkedColor = colors.foreground,
                uncheckedColor = colors.secondary,
            ),
        )
    }
}

@Composable
private fun TweakActionField(tweak: SnapOTweakEntry) {
    val action = tweak.value.value as SnapOTweakValue.Action
    val colors = ButtonDefaults.textButtonColors()
    Box(
        modifier = Modifier
            .sizeIn(minWidth = 48.dp, minHeight = TweakOverlayLayout.fieldRowHeight)
            .clickable(enabled = !action.conflicted, role = Role.Button) { SnapOTweaks.invokeAction(tweak.name) }
            .semantics {
                contentDescription = if (action.conflicted) "Conflict for ${tweak.name}" else "Run ${tweak.name}"
            },
        contentAlignment = Alignment.CenterEnd,
    ) {
        if (action.conflicted) {
            Text("Conflict", color = colors.disabledContentColor, style = MaterialTheme.typography.labelLarge)
        } else {
            Box(
                modifier = Modifier.size(28.dp).background(TweakOverlayColors.current.field, RoundedCornerShape(6.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painter = painterResource(R.drawable.snapo_tweaks_play),
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                    tint = colors.contentColor,
                )
            }
        }
    }
}

@Composable
private fun TweakSelectionField(tweak: SnapOTweakEntry) {
    val colors = TweakOverlayColors.current
    val selection = tweak.value.value as SnapOTweakValue.Selection
    var expanded by remember { mutableStateOf(false) }

    Box {
        TweakSelectionButton(
            name = tweak.name,
            value = selection.value,
            expanded = expanded,
            onClick = { expanded = true },
        )

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            containerColor = colors.field,
        ) {
            selection.options.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = option,
                            color = colors.foreground,
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
                                tint = colors.foreground,
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
private fun TweakSelectionButton(
    name: String,
    value: String,
    expanded: Boolean,
    onClick: () -> Unit,
) {
    val colors = TweakOverlayColors.current
    Row(
        modifier = Modifier
            .sizeIn(minWidth = 48.dp, minHeight = TweakOverlayLayout.fieldRowHeight)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Choose option for $name. Current value: $value" }
            .padding(vertical = 8.dp)
            .background(colors.field, RoundedCornerShape(6.dp))
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = value,
            modifier = Modifier.weight(1f, fill = false),
            color = colors.foreground,
            fontSize = 13.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Icon(
            painter = painterResource(R.drawable.snapo_tweaks_chevron_down),
            contentDescription = null,
            modifier = Modifier.rotate(if (expanded) 180f else 0f),
            tint = colors.foreground,
        )
    }
}

@Composable
private fun TweakIntegerEditor(
    tweak: SnapOTweakEntry,
    defaultValue: SnapOTweakValue.Integer,
    modifier: Modifier,
) {
    val value = tweak.value.value as SnapOTweakValue.Integer
    val origin = defaultValue.min ?: defaultValue.value

    TweakNumericEditor(
        committed = value.value.toString(),
        keyboardType = numericKeyboardType(defaultValue.min),
        modifier = modifier,
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
    modifier: Modifier,
) {
    val value = tweak.value.value as SnapOTweakValue.Floating
    val origin = defaultValue.min ?: defaultValue.value

    TweakNumericEditor(
        committed = value.value.toString(),
        keyboardType = numericKeyboardType(defaultValue.min),
        modifier = modifier,
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
    modifier: Modifier,
    onValueChange: (String) -> Unit,
) {
    val colors = TweakOverlayColors.current
    var draft by rememberSaveable { mutableStateOf(committed) }
    var isFocused by remember { mutableStateOf(false) }

    LaunchedEffect(committed, isFocused) {
        if (!isFocused || draft.toDoubleOrNull() != committed.toDoubleOrNull()) draft = committed
    }

    BasicTextField(
        value = draft,
        onValueChange = { updated ->
            draft = updated
            onValueChange(updated)
        },
        modifier = modifier.onFocusChanged { isFocused = it.isFocused },
        cursorBrush = SolidColor(colors.foreground),
        textStyle = TextStyle(
            color = colors.foreground,
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
        stepSize = defaultValue.step.coerceAtLeast(1).toDouble(),
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
        stepSize = defaultValue.step?.toDouble(),
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
    stepSize: Double?,
    modifier: Modifier = Modifier,
) {
    val colors = TweakOverlayColors.current
    val interactionSource = remember { MutableInteractionSource() }
    val density = LocalDensity.current.density
    var trackWidthPx by remember { mutableIntStateOf(0) }
    val fineStep = fineSliderScrubStep(valueRange, stepSize, trackWidthPx / density)

    Slider(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier
            .fillMaxWidth()
            .height(TweakOverlayLayout.fieldRowHeight)
            .padding(horizontal = ControlHorizontalPadding),
        valueRange = valueRange,
        steps = steps,
        interactionSource = interactionSource,
        thumb = {
            // Material reserves half the thumb width at each end for the rounded caps.
            Spacer(
                Modifier.size(SliderTrackHeight)
                    .scrubByStep(fineStep, value, valueRange, interactionSource, onValueChange)
                    .indication(interactionSource, ripple(bounded = false, radius = 16.dp)),
            )
        },
        track = { state ->
            Canvas(Modifier.fillMaxWidth().height(SliderTrackHeight).onSizeChanged { trackWidthPx = it.width }) {
                val startX = if (layoutDirection == LayoutDirection.Rtl) size.width else 0f
                val start = Offset(startX, center.y)
                val end = Offset(size.width - startX, center.y)
                val selected = lerp(start, end, state.coercedValueAsFraction)
                drawLine(colors.outline, start, end, size.height, StrokeCap.Round)
                drawLine(colors.foreground, start, selected, size.height, StrokeCap.Round)
                // A zero-length line has no end cap when the slider is at its minimum.
                drawCircle(colors.foreground, size.height / 2, selected)
                drawCircle(colors.surface, 2.5.dp.toPx(), selected)
            }
        },
    )
}

internal fun fineSliderScrubStep(
    range: ClosedFloatingPointRange<Float>,
    step: Double?,
    trackWidthDp: Float,
): Double? {
    if (step == null || step <= 0.0 || trackWidthDp <= 0f) return null
    val intervals = round((range.endInclusive.toDouble() - range.start.toDouble()) / step)
    return step.takeIf { intervals > trackWidthDp }
}

@Composable
private fun Modifier.scrubByStep(
    step: Double?,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    interactionSource: MutableInteractionSource,
    onValueChange: (Float) -> Unit,
): Modifier {
    if (step == null) return this
    val density = LocalDensity.current.density
    var unsnapped by remember { mutableDoubleStateOf(value.toDouble()) }
    val drag = rememberDraggableState { deltaPx ->
        // Keep fractional steps between pointer events. The caller snaps the published value.
        unsnapped = (unsnapped + deltaPx / density * step)
            .coerceIn(range.start.toDouble(), range.endInclusive.toDouble())
        onValueChange(unsnapped.toFloat())
    }
    return draggable(
        state = drag,
        orientation = Orientation.Horizontal,
        reverseDirection = LocalLayoutDirection.current == LayoutDirection.Rtl,
        interactionSource = interactionSource,
        onDragStarted = { unsnapped = value.toDouble() },
    )
}

@Composable
private fun TweakTextEditor(
    tweak: SnapOTweakEntry,
    modifier: Modifier,
) {
    val colors = TweakOverlayColors.current
    val value = tweak.value.value as SnapOTweakValue.Text

    BasicTextField(
        value = value.value,
        onValueChange = { updated ->
            SnapOTweaks.update(tweak.name, value.copy(value = updated))
        },
        modifier = modifier
            .heightIn(min = TweakOverlayLayout.fieldRowHeight)
            .semantics { contentDescription = "Edit ${tweak.name}" }
            .wrapContentHeight()
            .background(colors.field, RoundedCornerShape(5.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        cursorBrush = SolidColor(colors.foreground),
        textStyle = TextStyle(
            color = colors.foreground,
            fontSize = 13.sp,
        ),
        singleLine = true,
    )
}

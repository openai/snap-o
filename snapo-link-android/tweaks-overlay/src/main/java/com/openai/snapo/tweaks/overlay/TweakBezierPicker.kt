package com.openai.snapo.tweaks.overlay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.inset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.openai.snapo.tweaks.BezierCurve
import com.openai.snapo.tweaks.SnapOTweakEntry
import com.openai.snapo.tweaks.SnapOTweakValue
import com.openai.snapo.tweaks.SnapOTweaks
import kotlin.math.abs

private val GraphInset = 24.dp
private val CurveAccent = Color(0xFF5468FF)
private val SecondHandleAccent = Color(0xFFD07818)
private val CurvePresets = linkedMapOf(
    "Linear" to BezierCurve(1f / 3f, 1f / 3f, 2f / 3f, 2f / 3f),
    "Ease" to BezierCurve(0.25f, 0.1f, 0.25f, 1f),
    "Ease in" to BezierCurve(0.42f, 0f, 1f, 1f),
    "Ease out" to BezierCurve(0f, 0f, 0.58f, 1f),
    "Ease in out" to BezierCurve(0.42f, 0f, 0.58f, 1f),
)

internal object BezierViewport {
    fun point(x: Float, y: Float, width: Float, height: Float, padding: Float = 0f): Offset =
        Offset(padding + (width - 2f * padding) * x, padding + (height - 2f * padding) * (1f - y))

    fun value(position: Offset, width: Float, height: Float, padding: Float = 0f): Pair<Float, Float> =
        ((position.x - padding) / (width - 2f * padding)).coerceIn(0f, 1f) to
            (1f - (position.y - padding) / (height - 2f * padding)).coerceIn(0f, 1f)
}

internal fun moveBezierHandle(
    value: SnapOTweakValue.Curve,
    handle: Int,
    x: Float,
    y: Float,
): SnapOTweakValue.Curve {
    if (!x.isFinite() || !y.isFinite()) return value
    val boundedX = x.coerceIn(0f, 1f)
    val boundedY = y.coerceIn(value.yMin ?: 0f, value.yMax ?: 1f)
    return value.copy(
        value = if (handle == 0) {
            value.value.copy(x1 = boundedX, y1 = boundedY)
        } else {
            value.value.copy(x2 = boundedX, y2 = boundedY)
        }
    )
}

@Composable
internal fun TweakBezierChooser(tweak: SnapOTweakEntry, modifier: Modifier = Modifier) {
    val value = tweak.value.value as SnapOTweakValue.Curve
    var selectedHandle by remember(tweak.name) { mutableStateOf(0) }
    val update: (SnapOTweakValue.Curve) -> Unit = { SnapOTweaks.update(tweak.name, it) }
    BoxWithConstraints(modifier) {
        val graphSize = minOf(
            (maxHeight - 88.dp).coerceIn(96.dp, 220.dp),
            (maxWidth - 144.dp).coerceAtLeast(96.dp),
        )
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.fillMaxWidth().height(graphSize)) {
                CurvePresetButtons(value, Modifier.align(Alignment.CenterEnd).width(48.dp).height(graphSize), update)
                BezierGraph(
                    value,
                    selectedHandle,
                    { selectedHandle = it },
                    update,
                    Modifier.align(Alignment.Center).size(graphSize),
                )
            }
            Row(
                Modifier.widthIn(max = graphSize),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val x = if (selectedHandle == 0) value.value.x1 else value.value.x2
                val y = if (selectedHandle == 0) value.value.y1 else value.value.y2
                CurveCoordinate("X${selectedHandle + 1}", x, 0f, 1f, Modifier.weight(1f)) {
                    update(moveBezierHandle(value, selectedHandle, it, y))
                }
                CurveCoordinate(
                    "Y${selectedHandle + 1}",
                    y,
                    value.yMin ?: 0f,
                    value.yMax ?: 1f,
                    Modifier.weight(1f),
                ) {
                    update(moveBezierHandle(value, selectedHandle, x, it))
                }
            }
        }
    }
}

internal fun bezierPresetName(curve: BezierCurve): String = CurvePresets.entries.firstOrNull { (_, preset) ->
    abs(curve.x1 - preset.x1) < 0.00001f && abs(curve.y1 - preset.y1) < 0.00001f &&
        abs(curve.x2 - preset.x2) < 0.00001f && abs(curve.y2 - preset.y2) < 0.00001f
}?.key ?: "Custom"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CurvePresetButtons(
    value: SnapOTweakValue.Curve,
    modifier: Modifier,
    onChange: (SnapOTweakValue.Curve) -> Unit,
) {
    val currentPreset = bezierPresetName(value.value)
    Column(
        modifier,
        verticalArrangement = Arrangement.SpaceEvenly,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CurvePresets.forEach { (name, curve) ->
            val isSelected = name == currentPreset
            val allowed = listOf(curve.y1, curve.y2).all {
                it >= (value.yMin ?: 0f) && it <= (value.yMax ?: 1f)
            }
            TooltipBox(
                positionProvider = TooltipDefaults.rememberTooltipPositionProvider(),
                tooltip = { PlainTooltip { Text(name) } },
                state = rememberTooltipState(),
            ) {
                Box(
                    modifier = Modifier.size(32.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(if (isSelected) CurveAccent.copy(alpha = 0.15f) else Color.Transparent)
                        .clickable(enabled = allowed, role = Role.Button) { onChange(value.copy(value = curve)) }
                        .semantics {
                            contentDescription = "Apply $name curve"
                            selected = isSelected
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    BezierPreview(curve, Modifier.size(28.dp))
                }
            }
        }
    }
}

private fun validCoordinate(value: Float?, minimum: Float, maximum: Float): Boolean =
    value != null && value.isFinite() && value in minimum..maximum

@Composable
private fun CurveCoordinate(
    label: String,
    value: Float,
    minimum: Float,
    maximum: Float,
    modifier: Modifier,
    onChange: (Float) -> Unit,
) {
    var edit by remember(label) { mutableStateOf(value to value.toString()) }
    val draft = if (edit.first == value) edit.second else value.toString()
    val number = draft.toFloatOrNull()
    val valid = validCoordinate(number, minimum, maximum)
    OutlinedTextField(
        value = draft,
        onValueChange = { text ->
            edit = value to text
            val next = text.toFloatOrNull()
            if (next != null && validCoordinate(next, minimum, maximum)) {
                edit = next to text
                onChange(next)
            }
        },
        modifier = modifier,
        label = { Text(label) },
        isError = !valid,
        singleLine = true,
    )
}

@Composable
private fun BezierGraph(
    value: SnapOTweakValue.Curve,
    selected: Int,
    onSelect: (Int) -> Unit,
    onChange: (SnapOTweakValue.Curve) -> Unit,
    modifier: Modifier,
) {
    val shape = RoundedCornerShape(6.dp)
    Canvas(
        modifier.fillMaxWidth().aspectRatio(1f)
            .background(TweakOverlayColors.field, shape)
            .border(1.dp, TweakOverlayColors.outline, shape)
            .semantics {
                contentDescription = "Bezier curve. Touch a handle to select it, then drag or edit its coordinates."
                stateDescription = if (selected == 0) "Blue handle selected" else "Orange handle selected"
                customActions = listOf(
                    CustomAccessibilityAction("Select blue handle") {
                        onSelect(0)
                        true
                    },
                    CustomAccessibilityAction("Select orange handle") {
                        onSelect(1)
                        true
                    },
                )
            }
            .bezierGestures(value, selected, onSelect, onChange),
    ) {
        inset(GraphInset.toPx()) {
            drawLine(TweakOverlayColors.outline, Offset(0f, size.height / 2), Offset(size.width, size.height / 2))
            drawLine(TweakOverlayColors.outline, Offset(size.width / 2, 0f), Offset(size.width / 2, size.height))
            drawBezier(value.value, handles = true, selected = selected)
        }
    }
}

@Composable
private fun Modifier.bezierGestures(
    value: SnapOTweakValue.Curve,
    selected: Int,
    onSelect: (Int) -> Unit,
    onChange: (SnapOTweakValue.Curve) -> Unit,
): Modifier {
    val latest by rememberUpdatedState(value)
    val latestSelected by rememberUpdatedState(selected)
    val select by rememberUpdatedState(onSelect)
    val update by rememberUpdatedState(onChange)
    return pointerInput(Unit) {
        awaitEachGesture {
            val down = awaitFirstDown()
            val frame = BezierViewport
            val width = size.width.toFloat()
            val height = size.height.toFloat()
            val padding = GraphInset.toPx()
            val first = frame.point(latest.value.x1, latest.value.y1, width, height, padding)
            val second = frame.point(latest.value.x2, latest.value.y2, width, height, padding)
            val handle = bezierHandleAt(down.position, first, second, 24.dp.toPx(), latestSelected)
                ?: return@awaitEachGesture
            val grabOffset = (if (handle == 0) first else second) - down.position
            select(handle)
            down.consume()
            drag(down.id) { change ->
                change.consume()
                val (x, y) = frame.value(change.position + grabOffset, width, height, padding)
                update(moveBezierHandle(latest, handle, x, y))
            }
        }
    }
}

internal fun bezierHandleAt(position: Offset, first: Offset, second: Offset, radius: Float, selected: Int): Int? {
    val firstDistance = (first - position).getDistance()
    val secondDistance = (second - position).getDistance()
    if (minOf(firstDistance, secondDistance) > radius) return null
    // Repeated touches can reach either handle when the points coincide.
    if ((first - second).getDistance() < 1f) return 1 - selected
    return if (firstDistance <= secondDistance) 0 else 1
}

@Composable
internal fun TweakBezierField(tweak: SnapOTweakEntry, onClick: () -> Unit) {
    val curve = (tweak.value.value as SnapOTweakValue.Curve).value
    Box(
        modifier = Modifier
            .size(48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Edit curve for ${tweak.name}" },
        contentAlignment = Alignment.CenterEnd,
    ) {
        BezierPreview(curve, Modifier.size(28.dp))
    }
}

@Composable
private fun BezierPreview(curve: BezierCurve, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(4.dp)
    Canvas(
        modifier
            .clip(shape)
            .border(1.dp, TweakOverlayColors.outline, shape)
            .background(TweakOverlayColors.surface)
            .padding(3.dp),
    ) { drawBezier(curve, handles = false) }
}

private fun DrawScope.drawBezier(curve: BezierCurve, handles: Boolean, selected: Int = 0) {
    val viewport = BezierViewport
    val start = viewport.point(0f, 0f, size.width, size.height)
    val end = viewport.point(1f, 1f, size.width, size.height)
    val first = viewport.point(curve.x1, curve.y1, size.width, size.height)
    val second = viewport.point(curve.x2, curve.y2, size.width, size.height)
    if (handles) {
        drawLine(CurveAccent.copy(alpha = 0.6f), start, first)
        drawLine(SecondHandleAccent.copy(alpha = 0.6f), end, second)
    }
    val path = Path().apply {
        moveTo(start.x, start.y)
        cubicTo(first.x, first.y, second.x, second.y, end.x, end.y)
    }
    drawPath(path, CurveAccent, style = Stroke((if (handles) 2.dp else 1.5.dp).toPx()))
    if (handles) {
        val points = listOf(first, second)
        val colors = listOf(CurveAccent, SecondHandleAccent)
        for (index in listOf(1 - selected, selected)) {
            val point = points[index]
            val color = colors[index]
            if (index == selected) drawCircle(color, 12.dp.toPx(), point, style = Stroke(1.dp.toPx()))
            drawCircle(color, 8.dp.toPx(), point)
            drawCircle(TweakOverlayColors.surface, 8.dp.toPx(), point, style = Stroke(2.dp.toPx()))
        }
    }
}

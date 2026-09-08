package com.openai.snapo.tweaks.overlay

import androidx.compose.ui.geometry.Offset
import com.openai.snapo.tweaks.BezierCurve
import com.openai.snapo.tweaks.SnapOTweakValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TweakBezierPickerTest {
    private val viewport = BezierViewport(BezierCurve(0f, 0f, 1f, 1f))

    @Test
    fun `touches away from both handles do not select a handle`() {
        assertNull(bezierHandleAt(Offset(100f, 100f), Offset(40f, 180f), Offset(160f, 20f), 24f, 0))
        assertNull(bezierHandleAt(Offset(65f, 180f), Offset(40f, 180f), Offset(160f, 20f), 24f, 0))
    }

    @Test
    fun `touch selects the nearest handle within the hit radius`() {
        val first = Offset(40f, 100f)
        val second = Offset(70f, 100f)
        assertEquals(0, bezierHandleAt(Offset(16f, 100f), first, second, 24f, 1))
        assertEquals(1, bezierHandleAt(Offset(65f, 100f), first, second, 24f, 0))
    }

    @Test
    fun `coincident handles remain reachable without selecting on distant touches`() {
        val point = Offset(100f, 100f)
        assertEquals(1, bezierHandleAt(point, point, point, 24f, 0))
        assertEquals(0, bezierHandleAt(point, point, point, 24f, 1))
        assertNull(bezierHandleAt(Offset.Zero, point, point, 24f, 0))
    }

    @Test
    fun `preset name follows curve edits and tolerates float rounding`() {
        assertEquals("Ease", bezierPresetName(BezierCurve(0.25f, 0.1f, 0.25f, 1f)))
        assertEquals("Ease", bezierPresetName(BezierCurve(0.250001f, 0.1f, 0.25f, 1f)))
        assertEquals("Custom", bezierPresetName(BezierCurve(0.3f, 0.1f, 0.25f, 1f)))
    }

    @Test
    fun `moving one handle preserves the other and clamps only X`() {
        val original = SnapOTweakValue.Curve(BezierCurve(0.2f, 0.3f, 0.8f, 0.9f))
        assertEquals(BezierCurve(0f, 2f, 0.8f, 0.9f), moveBezierHandle(original, 0, -1f, 2f).value)
        assertEquals(original, moveBezierHandle(original, 0, Float.NaN, 0f))
    }

    @Test
    fun `viewport round trips overshoot coordinates`() {
        val point = viewport.point(0.2f, 1.25f, 240f, 240f)
        val (x, y) = viewport.value(point, 240f, 240f)
        assertEquals(0.2f, x, 0.00001f)
        assertEquals(1.25f, y, 0.00001f)
        assertEquals(0f, viewport.value(Offset(-20f, -20f), 240f, 240f).first)
        assertEquals(1.666667f, viewport.value(Offset(-20f, -20f), 240f, 240f).second, 0.00001f)
    }

    @Test
    fun `viewport supports both finite Float extremes`() {
        val curve = BezierCurve(0f, -Float.MAX_VALUE, 1f, Float.MAX_VALUE)
        val frame = BezierViewport(curve)
        for (y in listOf(curve.y1, curve.y2)) {
            val point = frame.point(0.5f, y, 240f, 240f)
            assertEquals(y, frame.value(point, 240f, 240f).second)
        }
    }

    @Test
    fun `padding touches reach corner handles without shifting their values`() {
        val first = viewport.point(0f, 0f, 200f, 200f, 24f)
        val second = viewport.point(1f, 1f, 200f, 200f, 24f)
        val touch = first + Offset(-16f, 16f)
        assertEquals(0, bezierHandleAt(touch, first, second, 24f, 1))
        assertEquals(1, bezierHandleAt(second + Offset(16f, -16f), first, second, 24f, 0))
        val grabOffset = first - touch
        assertEquals(0f to 0f, viewport.value(touch + grabOffset, 200f, 200f, 24f))
        val (x, y) = viewport.value(touch + grabOffset + Offset(76f, -38f), 200f, 200f, 24f)
        assertEquals(0.5f, x, 0.00001f)
        assertEquals(0.5f, y, 0.00001f)
        assertEquals(1f, viewport.value(Offset(200f, 0f), 200f, 200f, 24f).first)
    }
}

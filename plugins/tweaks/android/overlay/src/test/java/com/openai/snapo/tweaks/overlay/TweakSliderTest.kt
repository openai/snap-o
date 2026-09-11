package com.openai.snapo.tweaks.overlay

import androidx.compose.ui.text.input.KeyboardType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakSliderTest {

    @Test
    fun `integer slider exposes only values aligned with its minimum and step`() {
        val snapper = IntegerSliderSnapper(min = 2, max = 12, step = 4)

        assertEquals(10, snapper.effectiveMaximum)
        assertEquals(1, snapper.materialSteps)
        assertEquals(2, snapper.snap(2f))
        assertEquals(6, snapper.snap(5.9f))
        assertEquals(10, snapper.snap(12f))
    }

    @Test
    fun `integer slider supports negative ranges without overflowing its travel`() {
        val snapper = IntegerSliderSnapper(min = -9, max = 4, step = 4)

        assertEquals(3, snapper.effectiveMaximum)
        assertEquals(2, snapper.materialSteps)
        assertEquals(-5, snapper.snap(-4f))
        assertEquals(3, snapper.snap(4f))
    }

    @Test
    fun `large integer ranges remain continuous while still snapping submitted values`() {
        val snapper = IntegerSliderSnapper(min = -2_000, max = 2_000, step = 1)

        assertEquals(2_000, snapper.effectiveMaximum)
        assertEquals(0, snapper.materialSteps)
        assertEquals(-201, snapper.snap(-201.2f))
    }

    @Test
    fun `integer ranges collapse to a text editor when float cannot represent adjacent values`() {
        assertFalse(
            hasRepresentableIntegerSliderBounds(
                min = Int.MAX_VALUE - 1,
                max = Int.MAX_VALUE,
                step = 1,
            ),
        )
        assertTrue(hasRepresentableIntegerSliderBounds(min = -2_000, max = 2_000, step = 1))
    }

    @Test
    fun `integer sliders still support exactly representable high magnitude intervals`() {
        assertTrue(
            hasRepresentableIntegerSliderBounds(
                min = 1_000_000_000,
                max = 1_000_001_024,
                step = 128,
            ),
        )
    }

    @Test
    fun `floating point slider removes rounding noise from valid steps`() {
        assertEquals(
            0.7f,
            snapFloatingSliderValue(
                value = 0.70000005f,
                min = 0.1f,
                max = 1f,
                step = 0.05f,
            ),
        )
    }

    @Test
    fun `floating point slider rounds to the nearest declared step`() {
        assertEquals(
            0.75f,
            snapFloatingSliderValue(
                value = 0.731f,
                min = 0.1f,
                max = 1f,
                step = 0.05f,
            ),
        )
    }

    @Test
    fun `floating point slider rounds midpoint ties toward the higher step`() {
        assertEquals(
            1f,
            snapFloatingSliderValue(
                value = 0.5f,
                min = 0f,
                max = 1f,
                step = 1f,
            ),
        )
    }

    @Test
    fun `floating point slider does not exceed the last valid step`() {
        assertEquals(
            0.9f,
            snapFloatingSliderValue(
                value = 1f,
                min = 0f,
                max = 1f,
                step = 0.3f,
            ),
        )
    }

    @Test
    fun `floating point slider exposes an aligned effective range and material steps`() {
        val snapper = FloatingSliderSnapper(min = 0.1f, max = 1f, step = 0.2f)

        assertEquals(0.9f, snapper.effectiveMaximum)
        assertEquals(3, snapper.materialSteps)
        assertEquals(0.9f, snapper.snap(1f))
    }

    @Test
    fun `continuous floating point slider preserves its full range`() {
        val snapper = FloatingSliderSnapper(min = -1f, max = 1f, step = null)

        assertEquals(1f, snapper.effectiveMaximum)
        assertEquals(0, snapper.materialSteps)
        assertEquals(0.35f, snapper.snap(0.35f))
    }

    @Test
    fun `large floating point ranges avoid material tick allocation while snapping`() {
        val snapper = FloatingSliderSnapper(min = 0f, max = 200f, step = 0.1f)

        assertEquals(200f, snapper.effectiveMaximum)
        assertEquals(0, snapper.materialSteps)
        assertEquals(120.1f, snapper.snap(120.12f))
    }

    @Test
    fun `tiny floating point intervals do not overflow their slider step count`() {
        val snapper = FloatingSliderSnapper(min = 0f, max = 1f, step = 1e-10f)

        assertEquals(1f, snapper.effectiveMaximum)
        assertEquals(0, snapper.materialSteps)
        assertEquals(0.5f, snapper.snap(0.5f))
        assertFalse(hasRepresentableFloatingSliderBounds(0f, 1f, 1e-10f))
    }

    @Test
    fun `smallest possible floating point increment does not overflow its slider step count`() {
        val snapper = FloatingSliderSnapper(min = 0f, max = 1f, step = Float.MIN_VALUE)

        assertEquals(1f, snapper.effectiveMaximum)
        assertEquals(0, snapper.materialSteps)
        assertFalse(hasRepresentableFloatingSliderBounds(0f, 1f, Float.MIN_VALUE))
    }

    @Test
    fun `floating point grids that cannot be represented fall back to a text editor`() {
        assertFalse(
            hasRepresentableFloatingSliderBounds(
                min = 100_000_000f,
                max = 100_000_100f,
                step = 0.3f,
            ),
        )
        assertFalse(
            hasRepresentableFloatingSliderBounds(
                min = 1_000_000f,
                max = 1_000_001f,
                step = 0.07f,
            ),
        )
        assertTrue(hasRepresentableFloatingSliderBounds(min = 0.1f, max = 1f, step = 0.05f))
    }

    @Test
    fun `floating point slider without a step preserves its bounded value`() {
        assertEquals(
            0.731f,
            snapFloatingSliderValue(
                value = 0.731f,
                min = 0.1f,
                max = 1f,
                step = null,
            ),
        )
    }

    @Test
    fun `floating point slider preserves the decimal precision of its increment`() {
        assertEquals(
            0.73f,
            snapFloatingSliderValue(
                value = 0.73100007f,
                min = 0.1f,
                max = 1f,
                step = 0.03f,
            ),
        )
    }

    @Test
    fun `floating point slider snaps negative ranges without binary rounding noise`() {
        assertEquals(
            -0.25f,
            snapFloatingSliderValue(
                value = -0.24000001f,
                min = -1f,
                max = 1f,
                step = 0.05f,
            ),
        )
    }

    @Test
    fun `integer text editor enforces optional bounds and steps`() {
        assertTrue(isValidIntegerEditorValue(11, min = null, max = 20, step = 3, origin = 5))
        assertFalse(isValidIntegerEditorValue(12, min = null, max = 20, step = 3, origin = 5))
        assertFalse(isValidIntegerEditorValue(23, min = null, max = 20, step = 3, origin = 5))
    }

    @Test
    fun `floating text editor enforces decimal steps relative to its origin`() {
        assertTrue(
            isValidFloatingEditorValue(
                value = 0.75f,
                min = null,
                max = 1f,
                step = 0.05f,
                origin = 0.7f,
            ),
        )
        assertFalse(
            isValidFloatingEditorValue(
                value = 0.73f,
                min = null,
                max = 1f,
                step = 0.05f,
                origin = 0.7f,
            ),
        )
        assertFalse(
            isValidFloatingEditorValue(
                value = Float.NaN,
                min = null,
                max = 1f,
                step = 0.05f,
                origin = 0.7f,
            ),
        )
    }

    @Test
    fun `numeric editors use a signed keyboard when negative values are allowed`() {
        assertEquals(KeyboardType.Text, numericKeyboardType(minimum = null))
        assertEquals(KeyboardType.Text, numericKeyboardType(minimum = -1))
        assertEquals(KeyboardType.Text, numericKeyboardType(minimum = -0.5f))
        assertEquals(KeyboardType.Decimal, numericKeyboardType(minimum = 0))
        assertEquals(KeyboardType.Decimal, numericKeyboardType(minimum = 0.5f))
    }
}

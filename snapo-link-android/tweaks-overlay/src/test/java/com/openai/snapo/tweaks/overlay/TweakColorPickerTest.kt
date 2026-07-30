package com.openai.snapo.tweaks.overlay

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TweakColorPickerTest {

    @Test
    fun `picker converts primary hues to sRGB colors`() {
        assertEquals(Color.Red, PickerColor(0f, 1f, 1f, 1f).toComposeColor())
        assertEquals(Color.Green, PickerColor(120f, 1f, 1f, 1f).toComposeColor())
        assertEquals(Color.Blue, PickerColor(240f, 1f, 1f, 1f).toComposeColor())
    }

    @Test
    fun `picker normalizes hue and clamps channels`() {
        val color = PickerColor(
            hue = -120f,
            saturation = 2f,
            brightness = 2f,
            alpha = -1f,
        ).toComposeColor()

        assertEquals(Color.Blue.copy(alpha = 0f), color)
    }

    @Test
    fun `picker reads projected rgb while preserving current alpha`() {
        val color = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 0.3f,
        )

        val picker = requireNotNull(color.toPickerColorOrNull())

        assertEquals(210f, picker.hue, 0.5f)
        assertEquals(2f / 3f, picker.saturation, 0.01f)
        assertEquals(0.75f, picker.brightness, 0.01f)
        assertEquals(color.alpha, picker.alpha, 0f)
    }

    @Test
    fun `unspecified colors do not initialize a concrete picker value`() {
        assertNull(Color.Unspecified.toPickerColorOrNull())
        assertEquals("Unspecified", Color.Unspecified.toPickerLabel())
    }

    @Test
    fun `picker labels make alpha visible without a keyboard`() {
        assertEquals("#11223380", Color(0x80112233).toPickerLabel())
        assertEquals("#112233", Color(0xFF112233).toPickerLabel())
    }

    @Test
    fun `picker keeps a staged hue when a neutral color cannot encode it`() {
        val state = ColorPickerState(PickerColor(0f, 0f, 1f, 1f))
        var emitted: Color? = null

        state.select(state.color.copy(hue = 240f)) { updated -> emitted = updated }
        state.sync(requireNotNull(emitted))

        assertEquals(Color.White, emitted)
        assertEquals(240f, state.color.hue, 0f)
    }

    @Test
    fun `opacity edits preserve exact source color components and color space`() {
        val source = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 0.3f,
            colorSpace = ColorSpaces.DisplayP3,
        )
        val state = ColorPickerState(requireNotNull(source.toPickerColorOrNull()))
        var emitted: Color? = null

        state.selectAlpha(0.7f, source) { updated -> emitted = updated }

        val updated = requireNotNull(emitted)
        assertEquals(source.red, updated.red, 0f)
        assertEquals(source.green, updated.green, 0f)
        assertEquals(source.blue, updated.blue, 0f)
        assertEquals(0.7f, updated.alpha, 0.001f)
        assertEquals(ColorSpaces.DisplayP3, updated.colorSpace)
    }
}

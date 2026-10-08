package com.openai.snapo.tweaks.overlay

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakOverlayThemeTest {
    @Test
    fun `labels and cursors contrast with both overlay surfaces`() {
        for (colors in listOf(TweakOverlayColors.Light, TweakOverlayColors.Dark)) {
            for (surface in listOf(colors.surface, colors.field)) {
                assertContrast(colors.foreground, surface, 4.5f)
                assertContrast(colors.secondary, surface, 4.5f)
                assertContrast(colors.curve, surface, 3f)
                assertContrast(colors.secondHandle, surface, 3f)
            }
        }
    }

    @Test
    fun `material actions checkmarks and menus contrast in both themes`() {
        for (darkTheme in listOf(false, true)) {
            val scheme = tweakOverlayColorScheme(darkTheme)
            // Run labels use primary on surface; checked boxes use onPrimary on primary.
            assertContrast(scheme.primary, scheme.surface, 4.5f)
            assertContrast(scheme.onPrimary, scheme.primary, 4.5f)
            assertContrast(scheme.onSurface, scheme.surfaceContainer, 4.5f)
            assertContrast(scheme.onSurfaceVariant, scheme.surfaceContainer, 4.5f)
            assertContrast(scheme.error, scheme.surface, 4.5f)
            assertContrast(scheme.inverseOnSurface, scheme.inverseSurface, 4.5f)
        }
    }

    private fun assertContrast(foreground: Color, background: Color, minimum: Float) {
        val lighter = maxOf(foreground.luminance(), background.luminance())
        val darker = minOf(foreground.luminance(), background.luminance())
        val ratio = (lighter + 0.05f) / (darker + 0.05f)
        assertTrue("Expected contrast >= $minimum, was $ratio", ratio >= minimum)
    }
}

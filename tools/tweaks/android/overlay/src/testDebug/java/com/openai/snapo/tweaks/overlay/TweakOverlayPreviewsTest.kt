package com.openai.snapo.tweaks.overlay

import com.openai.snapo.tweaks.internal.TweakType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakOverlayPreviewsTest {
    @Test
    fun `all controls preview covers every tweak type`() {
        val types = allControlPreviewSamples.map { it.type }.toSet()
        assertEquals(TweakType.entries.toSet(), types)
    }

    @Test
    fun `all controls preview includes sliders and text editors for both numeric types`() {
        for (type in listOf(TweakType.INT, TweakType.FLOAT)) {
            val samples = allControlPreviewSamples.filter { it.type == type }
            assertTrue("Missing $type slider", samples.any { it.min != null && it.max != null })
            assertTrue("Missing $type text editor", samples.any { it.min == null && it.max == null })
        }
    }
}

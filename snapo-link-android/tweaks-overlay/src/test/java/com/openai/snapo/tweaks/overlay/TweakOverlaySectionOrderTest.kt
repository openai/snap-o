package com.openai.snapo.tweaks.overlay

import org.junit.Assert.assertEquals
import org.junit.Test

class TweakOverlaySectionOrderTest {

    @Test
    fun `interleaved tweak sections become contiguous`() {
        val ordering = TweakOverlaySectionOrder()

        val ordered = ordering.arrange(
            listOf("Typography/Font size", "Motion/Duration", "Typography/Font weight"),
        ) { tweak ->
            tweak.substringBefore('/')
        }

        assertEquals(
            listOf("Typography/Font size", "Typography/Font weight", "Motion/Duration"),
            ordered,
        )
    }

    @Test
    fun `section order survives its first tweak disappearing`() {
        val ordering = TweakOverlaySectionOrder()
        val section: (String) -> String = { tweak -> tweak.substringBefore('/') }

        ordering.arrange(
            listOf("Typography/Font size", "Motion/Duration", "Typography/Font weight"),
            section,
        )

        assertEquals(
            listOf("Typography/Font weight", "Motion/Duration"),
            ordering.arrange(listOf("Motion/Duration", "Typography/Font weight"), section),
        )
    }

    @Test
    fun `section order survives every tweak temporarily leaving composition`() {
        val ordering = TweakOverlaySectionOrder()
        val section: (String) -> String = { tweak -> tweak.substringBefore('/') }

        ordering.arrange(listOf("Typography/Font size", "Motion/Duration"), section)
        ordering.arrange(emptyList(), section)

        assertEquals(
            listOf("Typography/Font size", "Motion/Duration"),
            ordering.arrange(listOf("Motion/Duration", "Typography/Font size"), section),
        )
    }

    @Test
    fun `sorting new sections does not record them before composition succeeds`() {
        val ordering = TweakOverlaySectionOrder()
        val section: (String) -> String = { tweak -> tweak.substringBefore('/') }

        ordering.sorted(listOf("Motion/Duration", "Typography/Font size"), section)
        ordering.observe(listOf("Typography/Font size", "Motion/Duration"), section)

        assertEquals(
            listOf("Typography/Font size", "Motion/Duration"),
            ordering.sorted(listOf("Motion/Duration", "Typography/Font size"), section),
        )
    }
}

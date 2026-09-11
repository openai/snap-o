package com.openai.snapo.tweaks.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SnapOTweakOverlaySettingsTest {

    @Test
    fun `stored setting is restored when there is no pending change`() {
        assertTrue(resolveOverlayEnabled(pendingEnabled = null) { true })
        assertFalse(resolveOverlayEnabled(pendingEnabled = null) { false })
    }

    @Test
    fun `enabling the overlay before initialization overrides stored state`() {
        assertTrue(resolveOverlayEnabled(pendingEnabled = true) { false })
    }

    @Test
    fun `disabling the overlay before initialization overrides stored state`() {
        assertFalse(resolveOverlayEnabled(pendingEnabled = false) { true })
    }

    @Test
    fun `pending enabled override does not read stored preferences`() {
        var preferenceWasRead = false

        assertFalse(
            resolveOverlayEnabled(pendingEnabled = false) {
                preferenceWasRead = true
                true
            },
        )
        assertFalse(preferenceWasRead)
    }

    @Test
    fun `enabled setting reads stored preferences when there is no override`() {
        var preferenceWasRead = false

        assertTrue(
            resolveOverlayEnabled(pendingEnabled = null) {
                preferenceWasRead = true
                true
            },
        )
        assertTrue(preferenceWasRead)
    }

    @Test
    fun `overlay positions preserve their normalized values`() {
        assertEquals(1f, normalizeOverlayPosition(position = 1f, defaultPosition = 1f))
        assertEquals(0.48f, normalizeOverlayPosition(position = 0.48f, defaultPosition = 0.48f))
        assertEquals(0.25f, normalizeOverlayPosition(position = 0.25f, defaultPosition = 1f))
    }

    @Test
    fun `overlay positions restore their persisted values`() {
        assertEquals(
            0.25f,
            resolveOverlayPosition(pendingPosition = null, defaultPosition = 1f) { 0.25f },
        )
        assertEquals(
            0.75f,
            resolveOverlayPosition(pendingPosition = null, defaultPosition = 0.48f) { 0.75f },
        )
    }

    @Test
    fun `pending overlay positions override persisted values without reading them`() {
        var preferenceWasRead = false

        assertEquals(
            0.35f,
            resolveOverlayPosition(pendingPosition = 0.35f, defaultPosition = 1f) {
                preferenceWasRead = true
                0.9f
            },
        )
        assertFalse(preferenceWasRead)
    }

    @Test
    fun `overlay positions remain inside the available window`() {
        assertEquals(0f, normalizeOverlayPosition(position = -0.5f, defaultPosition = 1f))
        assertEquals(1f, normalizeOverlayPosition(position = 1.5f, defaultPosition = 0.48f))
    }

    @Test
    fun `invalid persisted overlay positions restore their defaults`() {
        assertEquals(1f, normalizeOverlayPosition(position = Float.NaN, defaultPosition = 1f))
        assertEquals(
            0.48f,
            normalizeOverlayPosition(position = Float.POSITIVE_INFINITY, defaultPosition = 0.48f),
        )
    }
}

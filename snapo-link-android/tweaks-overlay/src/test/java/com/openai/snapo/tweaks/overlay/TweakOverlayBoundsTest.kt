package com.openai.snapo.tweaks.overlay

import androidx.compose.ui.unit.IntSize
import org.junit.Assert.assertEquals
import org.junit.Test

class TweakOverlayBoundsTest {

    @Test
    fun `collapsed button can travel across its measured parent`() {
        val bounds = TweakOverlayBounds()
        bounds.containerSize = IntSize(300, 500)
        bounds.buttonSize = IntSize(52, 52)

        assertEquals(248, bounds.horizontalTravel)
        assertEquals(448, bounds.verticalTravel(isExpanded = false))
    }

    @Test
    fun `expanded panel uses its measured parent for vertical travel`() {
        val bounds = TweakOverlayBounds()
        bounds.containerSize = IntSize(300, 500)
        bounds.panelSize = IntSize(280, 320)

        assertEquals(180, bounds.verticalTravel(isExpanded = true))
    }

    @Test
    fun `collapsed travel uses the measured button width and height independently`() {
        val bounds = TweakOverlayBounds()
        bounds.containerSize = IntSize(300, 500)
        bounds.buttonSize = IntSize(52, 64)

        assertEquals(248, bounds.horizontalTravel)
        assertEquals(436, bounds.verticalTravel(isExpanded = false))
    }

    @Test
    fun `changing the measured panel height updates expanded travel`() {
        val bounds = TweakOverlayBounds()
        bounds.containerSize = IntSize(300, 500)
        bounds.panelSize = IntSize(280, 320)
        bounds.panelSize = IntSize(280, 240)

        assertEquals(260, bounds.verticalTravel(isExpanded = true))
    }

    @Test
    fun `travel never becomes negative when the parent is smaller than the overlay`() {
        val bounds = TweakOverlayBounds()
        bounds.containerSize = IntSize(40, 30)
        bounds.buttonSize = IntSize(52, 52)
        bounds.panelSize = IntSize(280, 320)

        assertEquals(0, bounds.horizontalTravel)
        assertEquals(0, bounds.verticalTravel(isExpanded = false))
        assertEquals(0, bounds.verticalTravel(isExpanded = true))
    }
}

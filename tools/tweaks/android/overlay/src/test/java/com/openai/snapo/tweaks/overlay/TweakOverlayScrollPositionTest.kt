package com.openai.snapo.tweaks.overlay

import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.unit.dp
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import com.openai.snapo.tweaks.tweak
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w400dp-h700dp")
class TweakOverlayScrollPositionTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()
    private val colorName = "Accent color"
    private val controls = List(30) { if (it == 15) colorName else "Control $it" }
    private var activeControls by mutableStateOf(controls)

    @Before
    fun openScrolledOverlay() {
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)
        SnapOTweakOverlaySettings.isEnabled = true
        compose.setContent {
            activeControls.forEach { name ->
                key(name) {
                    if (name == colorName) tweak(Color.Blue, name) else tweak(false, name)
                }
            }
            SnapOTweakOverlay()
        }
        open()
        val list = compose.onNode(hasScrollAction())
        list.performScrollToIndex(12)
        list.performSemanticsAction(SemanticsActions.ScrollBy) { scroll ->
            scroll(0f, with(compose.density) { 20.dp.toPx() })
        }
    }

    @After
    fun clearTweaks() {
        SnapOTweakOverlaySettings.isEnabled = false
        TweakRegistry.clear()
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
    }

    @Test
    fun `reopening restores a partially scrolled row`() {
        val top = labelTop("Control 13")
        close()
        open()
        assertEquals(top, labelTop("Control 13"), 0f)
    }

    @Test
    fun `closing the color editor returns the swatch to its saved height`() {
        val top = labelTop(colorName)
        openColorEditor()
        compose.onNodeWithContentDescription("Done editing $colorName").assertIsDisplayed().performClick()

        assertEquals(top, labelTop(colorName), 0f)
    }

    @Test
    fun `Android back returns from the color editor before the host handles back`() {
        var hostBackCount = 0
        val dispatcher = compose.activity.onBackPressedDispatcher
        compose.runOnIdle {
            dispatcher.addCallback(compose.activity) { hostBackCount++ }
        }
        val top = labelTop(colorName)
        openColorEditor()
        compose.runOnIdle { dispatcher.onBackPressed() }

        assertEquals(top, labelTop(colorName), 0f)
        compose.runOnIdle {
            assertEquals(0, hostBackCount)
            dispatcher.onBackPressed()
            assertEquals(1, hostBackCount)
        }
    }

    @Test
    fun `the next visible control stays in place when the first one disappears`() {
        val top = labelTop("Control 13")
        close()
        compose.runOnIdle { activeControls = controls.drop(4) - "Control 12" }
        open()
        assertEquals(top, labelTop("Control 13"), 0f)

        close()
        compose.runOnIdle { activeControls = controls - "Control 12" }
        open()
        assertEquals(top, labelTop("Control 13"), 0f)
    }

    @Test
    fun `controls can all disappear and return while collapsed`() {
        val top = labelTop("Control 13")
        close()
        compose.runOnIdle { activeControls = emptyList() }
        compose.onNodeWithContentDescription("Open tweaks").assertDoesNotExist()
        compose.runOnIdle { activeControls = controls.drop(6).reversed() }
        open()
        assertEquals(top, labelTop("Control 13"), 0f)
    }

    @Test
    fun `replacement controls use the old index within the new list`() {
        val top = labelTop("Control 13")
        close()
        compose.runOnIdle { activeControls = List(24) { "Replacement $it" } }
        open()
        assertEquals(top, labelTop("Replacement 13"), 0f)

        close()
        compose.runOnIdle { activeControls = List(3) { "Short $it" } }
        open()
        compose.onNodeWithText("Short 0").assertIsDisplayed()
        compose.onNodeWithText("Short 2").assertIsDisplayed()
    }

    private fun open() = compose.onNodeWithContentDescription("Open tweaks").performClick()
    private fun close() = compose.onNodeWithContentDescription("Minimize tweaks").performClick()
    private fun openColorEditor() =
        compose.onNodeWithContentDescription("Choose color for $colorName.", substring = true).performClick()
    private fun labelTop(name: String) = compose.onNodeWithText(name).fetchSemanticsNode().boundsInRoot.top
}

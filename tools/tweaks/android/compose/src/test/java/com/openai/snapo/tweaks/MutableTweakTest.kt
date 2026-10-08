package com.openai.snapo.tweaks

import androidx.compose.runtime.MutableState
import androidx.compose.ui.test.junit4.createComposeRule
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MutableTweakTest {
    @get:Rule
    val compose = createComposeRule()

    @Before
    fun allowTweaks() {
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)
    }

    @After
    fun clearTweaks() {
        TweakRegistry.clear()
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
    }

    @Test
    fun `app and tool edits update the same state`() {
        lateinit var state: MutableState<Mode>
        var rendered = Mode.Compact
        compose.setContent {
            state = tweak(Mode.Compact, "Mode")
            rendered = state.value
        }

        compose.runOnIdle {
            state.value = Mode.Expanded
            assertEquals("Expanded", TweakRegistry.snapshot().single().value)
        }
        compose.runOnIdle {
            assertEquals(Mode.Expanded, rendered)
            TweakRegistry.update(mapOf("Mode" to null))
        }
        compose.runOnIdle {
            assertEquals(Mode.Compact, state.value)
            assertEquals(Mode.Compact, rendered)
        }
    }

    @Test
    fun `app edits cannot bypass tweak validation`() {
        lateinit var state: MutableState<Int>
        compose.setContent { state = tweak(4, "Count", 0..10, 2) }

        compose.runOnIdle {
            assertThrows(IllegalArgumentException::class.java) { state.value = 3 }
            assertEquals(4, state.value)
        }
    }

    private enum class Mode { Compact, Expanded }
}

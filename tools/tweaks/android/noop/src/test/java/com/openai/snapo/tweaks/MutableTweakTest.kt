package com.openai.snapo.tweaks

import androidx.compose.runtime.MutableState
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.assertEquals
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

    @Test
    fun `local edits survive recomposition`() {
        lateinit var state: MutableState<Boolean>
        var rendered = false
        compose.setContent {
            state = tweak(false, "Enabled")
            rendered = state.value
        }

        compose.runOnIdle { state.value = true }
        compose.runOnIdle {
            assertEquals(true, state.value)
            assertEquals(true, rendered)
        }
    }

    @Test
    fun `source edits recompose without starting observation`() {
        var appValue = false
        val source = object : TweakSource<Boolean> {
            override var value: Boolean
                get() = appValue
                set(value) { appValue = value }

            override val isModified: Boolean
                get() = error("No-op must not inspect modification status")

            override fun reset() = error("No-op must not reset the source")
            override fun observe() = error("No-op must not observe the source")
        }
        lateinit var state: MutableState<Boolean>
        var rendered = false
        compose.setContent {
            state = tweak(source, "Enabled")
            rendered = state.value
        }

        compose.runOnIdle { state.value = true }
        compose.runOnIdle {
            assertEquals(true, appValue)
            assertEquals(true, state.value)
            assertEquals(true, rendered)
        }
    }
}

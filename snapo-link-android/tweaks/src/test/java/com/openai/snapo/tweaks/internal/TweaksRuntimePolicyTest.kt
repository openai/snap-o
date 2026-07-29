package com.openai.snapo.tweaks.internal

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TweaksRuntimePolicyTest {

    @After
    fun denyTweaksRuntime() {
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
    }

    @Test
    fun `debuggable applications enable live tweaks without a release override`() {
        assertTrue(
            TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false),
        )
        assertTrue(TweaksRuntimePolicy.isAllowed)
    }

    @Test
    fun `release applications disable live tweaks without an explicit override`() {
        assertFalse(
            TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false),
        )
        assertFalse(TweaksRuntimePolicy.isAllowed)
    }

    @Test
    fun `explicit release overrides enable live tweaks in release applications`() {
        assertTrue(
            TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = true),
        )
        assertTrue(TweaksRuntimePolicy.isAllowed)
    }

    @Test
    fun `release overrides do not disable tweaks in debuggable applications`() {
        assertTrue(
            TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = true),
        )
        assertTrue(TweaksRuntimePolicy.isAllowed)
    }

    @Test
    fun `denying a later configuration restores the fail-closed runtime policy`() {
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)

        assertFalse(
            TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false),
        )
        assertFalse(TweaksRuntimePolicy.isAllowed)
    }
}

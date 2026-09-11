package com.openai.snapo.plugin

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PluginStartupPolicyTest {

    @Test
    fun `debuggable builds start without release opt in`() {
        assertTrue(
            PluginStartupPolicy.isAllowed(
                isDebuggable = true,
                allowRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `release builds remain disabled without an opt in`() {
        assertFalse(
            PluginStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `application metadata enables release builds`() {
        assertTrue(
            PluginStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = false,
                applicationAllowsRelease = true,
            ),
        )
    }

    @Test
    fun `explicit configuration enables release builds without metadata`() {
        assertTrue(
            PluginStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = true,
                applicationAllowsRelease = false,
            ),
        )
    }
}

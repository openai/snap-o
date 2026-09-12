package com.openai.snapo.tool

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolStartupPolicyTest {

    @Test
    fun `debuggable builds start without release opt in`() {
        assertTrue(
            ToolStartupPolicy.isAllowed(
                isDebuggable = true,
                allowRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `release builds remain disabled without an opt in`() {
        assertFalse(
            ToolStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `application metadata enables release builds`() {
        assertTrue(
            ToolStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = false,
                applicationAllowsRelease = true,
            ),
        )
    }

    @Test
    fun `explicit configuration enables release builds without metadata`() {
        assertTrue(
            ToolStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = true,
                applicationAllowsRelease = false,
            ),
        )
    }
}

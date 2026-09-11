package com.openai.snapo.inspector

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InspectorStartupPolicyTest {

    @Test
    fun `debuggable builds start without release opt in`() {
        assertTrue(
            InspectorStartupPolicy.isAllowed(
                isDebuggable = true,
                allowRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `release builds remain disabled without an opt in`() {
        assertFalse(
            InspectorStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `application metadata enables release builds`() {
        assertTrue(
            InspectorStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = false,
                applicationAllowsRelease = true,
            ),
        )
    }

    @Test
    fun `explicit configuration enables release builds without metadata`() {
        assertTrue(
            InspectorStartupPolicy.isAllowed(
                isDebuggable = false,
                allowRelease = true,
                applicationAllowsRelease = false,
            ),
        )
    }
}

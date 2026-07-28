package com.openai.snapo.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkInspectorReleasePolicyTest {

    @Test
    fun `debuggable builds start without release opt in`() {
        assertTrue(
            isNetworkInspectorStartAllowed(
                isDebuggable = true,
                configAllowsRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `release builds remain disabled without an opt in`() {
        assertFalse(
            isNetworkInspectorStartAllowed(
                isDebuggable = false,
                configAllowsRelease = false,
                applicationAllowsRelease = false,
            ),
        )
    }

    @Test
    fun `application metadata enables release builds`() {
        assertTrue(
            isNetworkInspectorStartAllowed(
                isDebuggable = false,
                configAllowsRelease = false,
                applicationAllowsRelease = true,
            ),
        )
    }

    @Test
    fun `explicit configuration enables release builds without metadata`() {
        assertTrue(
            isNetworkInspectorStartAllowed(
                isDebuggable = false,
                configAllowsRelease = true,
                applicationAllowsRelease = false,
            ),
        )
    }
}

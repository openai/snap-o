package com.openai.snapo.tweaks.internal

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.Closeable

class TweakRegistryObserverTest {
    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `duplicate callbacks close independently and preserve notification order`() {
        val descriptor = TweakDescriptor("Preview/Size", TweakType.INT, 0)
        TweakRegistry.register(descriptor)
        val calls = mutableListOf<String>()
        val callback: () -> Unit = { calls.add("shared") }
        val first = TweakRegistry.observeChanges(callback)
        val middle = TweakRegistry.observeChanges { calls.add("middle") }
        val last = TweakRegistry.observeChanges(callback)
        try {
            last.close()
            last.close()
            TweakRegistry.update(mapOf(descriptor.name to 1))
            assertEquals(listOf("shared", "middle"), calls)
        } finally {
            first.close()
            middle.close()
            last.close()
        }
    }

    @Test
    fun `subscription changes during notification apply to the next dispatch`() {
        val descriptor = TweakDescriptor("Preview/Size", TweakType.INT, 0)
        TweakRegistry.register(descriptor)
        val calls = mutableListOf<String>()
        lateinit var second: Closeable
        var added: Closeable? = null
        val first = TweakRegistry.observeChanges {
            calls.add("first")
            if (added == null) {
                second.close()
                added = TweakRegistry.observeChanges { calls.add("added") }
            }
        }
        second = TweakRegistry.observeChanges { calls.add("second") }
        try {
            TweakRegistry.update(mapOf(descriptor.name to 1))
            assertEquals(listOf("first", "second"), calls)
            calls.clear()
            TweakRegistry.update(mapOf(descriptor.name to 2))
            assertEquals(listOf("first", "added"), calls)
        } finally {
            first.close()
            second.close()
            added?.close()
        }
    }
}

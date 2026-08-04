package com.openai.snapo.tweaks.internal

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakEnumRegistryLifecycleTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `conflicting enum defaults do not replace the existing declaration or selection`() {
        val descriptor = enumDescriptor("Lifecycle conflicting enum defaults")
        val original = TweakRegistry.register(descriptor)
        TweakRegistry.update(mapOf(descriptor.name to "Dark"))
        val conflicting = descriptor.copy(default = "Dark")

        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(conflicting)
        }

        assertEquals("Dark", original.value)
        assertEquals(descriptor, TweakRegistry.snapshot().single().descriptor)

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `conflicting enum option order or values do not acquire another registration`() {
        val descriptor = enumDescriptor("Lifecycle conflicting enum options")
        TweakRegistry.register(descriptor)

        listOf(
            descriptor.copy(options = descriptor.options.reversed()),
            descriptor.copy(options = listOf("System", "Light")),
        ).forEach { conflicting ->
            assertThrows(IllegalArgumentException::class.java) {
                TweakRegistry.register(conflicting)
            }
        }

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `enum selections survive removal and reject stale options from replacement declarations`() {
        val original = enumDescriptor("Lifecycle returning enum selection")
        val state = TweakRegistry.register(original)
        TweakRegistry.update(mapOf(original.name to "Dark"))
        TweakRegistry.unregister(original.name)

        val restored = TweakRegistry.register(original.copy())

        assertSame(state, restored)
        assertEquals("Dark", restored.value)

        TweakRegistry.unregister(original.name)

        val replacement = original.copy(options = listOf("System", "Light"))
        val replacementState = TweakRegistry.register(replacement)

        assertNotSame(state, replacementState)
        assertEquals("System", replacementState.value)

        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(mapOf(replacement.name to "Dark"))
        }

        assertEquals(422, error.statusCode)
        assertEquals("System", replacementState.value)
    }

    private fun enumDescriptor(name: String) = TweakDescriptor(
        name = name,
        type = TweakType.ENUM,
        default = "System",
        options = listOf("System", "Dark"),
    )
}

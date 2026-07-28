package com.openai.snapo.tweaks.internal

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakRegistryLifecycleTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `same-name registrations share state and survive until the final unregister`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle shared padding",
            type = TweakType.INT,
            default = 16,
            min = 0,
            max = 48,
            step = 1,
        )

        val first = TweakRegistry.register(descriptor)
        val second = TweakRegistry.register(descriptor.copy())

        assertSame(first, second)
        assertEquals(1, TweakRegistry.snapshot().size)

        TweakRegistry.update(mapOf(descriptor.name to 20))

        assertEquals(20, first.value)
        assertEquals(20, second.value)

        TweakRegistry.unregister(descriptor.name)

        assertEquals(1, TweakRegistry.snapshot().size)
        assertEquals(20, TweakRegistry.snapshot().single().value)

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `conflicting defaults do not replace an existing tweak`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle conflicting default",
            type = TweakType.INT,
            default = 16,
        )
        val original = TweakRegistry.register(descriptor)

        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(descriptor.copy(default = 20))
        }

        assertEquals(16, original.value)
        assertEquals(descriptor, TweakRegistry.snapshot().single().descriptor)
    }

    @Test
    fun `conflicting constraints do not acquire another registration`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle conflicting constraints",
            type = TweakType.INT,
            default = 16,
            min = 0,
            max = 48,
            step = 1,
        )
        TweakRegistry.register(descriptor)

        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(descriptor.copy(max = 64))
        }

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `conflicting types do not replace an existing tweak`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle conflicting type",
            type = TweakType.INT,
            default = 16,
        )
        TweakRegistry.register(descriptor)

        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = descriptor.name,
                    type = TweakType.STRING,
                    default = "16",
                ),
            )
        }

        assertEquals(descriptor, TweakRegistry.snapshot().single().descriptor)
    }

    @Test
    fun `integer and floating point tweaks cannot share the same name`() {
        val integer = TweakDescriptor(
            name = "Lifecycle conflicting numeric types",
            type = TweakType.INT,
            default = 16,
        )
        val state = TweakRegistry.register(integer)

        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(
                TweakDescriptor(
                    name = integer.name,
                    type = TweakType.FLOAT,
                    default = 16f,
                ),
            )
        }

        assertEquals(16, state.value)
        assertEquals(integer, TweakRegistry.snapshot().single().descriptor)

        TweakRegistry.unregister(integer.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `a removed name can register a fresh descriptor and default`() {
        val first = TweakDescriptor(
            name = "Lifecycle reused name",
            type = TweakType.INT,
            default = 16,
        )
        TweakRegistry.register(first)
        TweakRegistry.update(mapOf(first.name to 20))
        TweakRegistry.unregister(first.name)

        val replacement = first.copy(default = 32)
        val state = TweakRegistry.register(replacement)

        assertEquals(32, state.value)
        assertEquals(replacement, TweakRegistry.snapshot().single().descriptor)
    }

    @Test
    fun `snapshots preserve registration order`() {
        TweakRegistry.register(
            TweakDescriptor(
                name = "Lifecycle z tweak",
                type = TweakType.STRING,
                default = "last",
            ),
        )
        TweakRegistry.register(
            TweakDescriptor(
                name = "Lifecycle a tweak",
                type = TweakType.STRING,
                default = "first",
            ),
        )

        assertEquals(
            listOf("Lifecycle z tweak", "Lifecycle a tweak"),
            TweakRegistry.snapshot().map { it.descriptor.name },
        )
    }

    @Test
    fun `patching a tweak with its default resets its shared value`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle reset",
            type = TweakType.INT,
            default = 16,
        )
        val state = TweakRegistry.register(descriptor)
        TweakRegistry.update(mapOf(descriptor.name to 24))

        val updated = TweakRegistry.update(mapOf(descriptor.name to descriptor.default))

        assertEquals(16, state.value)
        assertEquals(16, updated.single().value)
    }
}

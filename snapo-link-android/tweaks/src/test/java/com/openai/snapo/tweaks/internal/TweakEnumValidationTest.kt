package com.openai.snapo.tweaks.internal

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakEnumValidationTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `enum tweaks accept only their exact constant names`() {
        val descriptor = enumDescriptor()
        val state = TweakRegistry.register(descriptor)

        TweakRegistry.update(mapOf(descriptor.name to "Dark"))

        assertEquals("Dark", state.value)
        assertInvalidUpdate(descriptor.name, "DARK")
        assertInvalidUpdate(descriptor.name, "Stale")
        assertInvalidUpdate(descriptor.name, true)
        assertInvalidUpdate(descriptor.name, null)
        assertEquals("Dark", state.value)
    }

    @Test
    fun `enum tweaks preserve declaration order and wire identity`() {
        val descriptor = enumDescriptor()

        TweakRegistry.register(descriptor)

        val snapshot = TweakRegistry.snapshot().single()
        assertEquals("enum", snapshot.descriptor.type.wireName)
        assertEquals("System", snapshot.value)
        assertEquals(listOf("System", "Light", "Dark"), snapshot.descriptor.options)
    }

    @Test
    fun `invalid enum descriptors are rejected before registration`() {
        val descriptor = enumDescriptor()

        listOf(
            descriptor.copy(default = false),
            descriptor.copy(default = "Missing"),
            descriptor.copy(options = emptyList()),
            descriptor.copy(options = listOf("")),
            descriptor.copy(options = listOf("   ")),
            descriptor.copy(options = listOf("System", "System")),
            descriptor.copy(min = 0),
            descriptor.copy(max = 1),
            descriptor.copy(step = 1),
        ).forEach { invalid ->
            assertThrows(IllegalArgumentException::class.java) {
                TweakRegistry.register(invalid)
            }
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `primitive tweaks cannot declare enum options`() {
        listOf(
            TweakDescriptor("Validation optioned string", TweakType.STRING, "System"),
            TweakDescriptor("Validation optioned boolean", TweakType.BOOLEAN, false),
            TweakDescriptor("Validation optioned integer", TweakType.INT, 1),
        ).forEach { descriptor ->
            assertThrows(IllegalArgumentException::class.java) {
                TweakRegistry.register(
                    descriptor.copy(options = listOf("System")),
                )
            }
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `invalid enum selections do not partially apply multi tweak updates`() {
        val selection = enumDescriptor()
        val count = TweakDescriptor("Validation atomic enum count", TweakType.INT, 2)
        val selectionState = TweakRegistry.register(selection)
        val countState = TweakRegistry.register(count)

        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(
                linkedMapOf(
                    count.name to 4,
                    selection.name to "Stale",
                ),
            )
        }

        assertEquals(422, error.statusCode)
        assertEquals("System", selectionState.value)
        assertEquals(2, countState.value)
    }

    private fun assertInvalidUpdate(name: String, value: Any?) {
        val error = assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(mapOf(name to value))
        }

        assertEquals(422, error.statusCode)
    }

    private fun enumDescriptor() = TweakDescriptor(
        name = "Validation appearance mode",
        type = TweakType.ENUM,
        default = "System",
        options = listOf("System", "Light", "Dark"),
    )
}

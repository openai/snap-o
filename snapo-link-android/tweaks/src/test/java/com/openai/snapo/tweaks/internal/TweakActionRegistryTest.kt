package com.openai.snapo.tweaks.internal

import com.openai.snapo.tweaks.SnapOTweakValue
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakActionRegistryTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `protocol version distinguishes reset and modification aware clients`() {
        assertEquals(4, TweaksProtocolVersion)
    }

    @Test
    fun `registered actions appear alongside value tweaks in composition order`() {
        val first = TweakDescriptor("Typography/Size", TweakType.INT, 16)
        val second = TweakDescriptor("Motion/Enabled", TweakType.BOOLEAN, true)

        TweakRegistry.register(first)
        TweakRegistry.registerAction("Playback/Restart") {}
        TweakRegistry.register(second)

        val snapshots = TweakRegistry.snapshot()

        assertEquals(
            listOf(first.name, "Playback/Restart", second.name),
            snapshots.map { it.descriptor.name },
        )
        assertEquals(TweakType.ACTION, snapshots[1].descriptor.type)
        assertEquals(SnapOTweakValue.Action(), snapshots[1].value)
        assertEquals(false, snapshots[1].modified)
        assertEquals(
            SnapOTweakValue.Action(),
            TweakRegistry.activeEntries().value[1].value.value,
        )
        assertEquals(false, TweakRegistry.activeEntries().value[1].modified.value)
    }

    @Test
    fun `invocation runs only its explicitly registered callback`() {
        var invocations = 0
        TweakRegistry.registerAction("Playback/Restart") { invocations += 1 }

        assertEquals(0, invocations)

        TweakRegistry.invokeAction("Playback/Restart")
        TweakRegistry.invokeAction("Playback/Restart")

        assertEquals(2, invocations)
    }

    @Test
    fun `separate owners with the same callback still conflict`() {
        var invocations = 0
        val callback = { invocations += 1 }
        TweakRegistry.registerAction("Playback/Restart", callback)
        TweakRegistry.registerAction("Playback/Restart", callback)

        val error = assertThrows(ConflictingTweakActionException::class.java) {
            TweakRegistry.invokeAction("Playback/Restart")
        }

        assertEquals(409, error.statusCode)
        assertTrue(error.message.orEmpty().contains("Playback/Restart"))
        assertEquals(0, invocations)
        assertEquals(
            SnapOTweakValue.Action(conflicted = true),
            TweakRegistry.snapshot().single().value,
        )
        assertEquals(
            SnapOTweakValue.Action(conflicted = true),
            TweakRegistry.activeEntries().value.single().value.value,
        )
    }

    @Test
    fun `conflicted actions recover only when their duplicate owner leaves`() {
        var originalInvocations = 0
        var duplicateInvocations = 0
        TweakRegistry.registerAction("Playback/Restart") {
            originalInvocations += 1
        }
        val duplicateRegistration = TweakRegistry.registerAction("Playback/Restart") {
            duplicateInvocations += 1
        }

        duplicateRegistration.close()

        assertEquals(SnapOTweakValue.Action(), TweakRegistry.snapshot().single().value)
        assertEquals(
            SnapOTweakValue.Action(),
            TweakRegistry.activeEntries().value.single().value.value,
        )

        TweakRegistry.invokeAction("Playback/Restart")

        assertEquals(1, originalInvocations)
        assertEquals(0, duplicateInvocations)
    }

    @Test
    fun `conflict changes notify snapshots without replacing observable entries`() {
        val conflicts = mutableListOf<Boolean>()
        val observer = TweakRegistry.observeChanges {
            TweakRegistry.snapshot().singleOrNull()?.let { snapshot ->
                conflicts += (snapshot.value as SnapOTweakValue.Action).conflicted
            }
        }
        TweakRegistry.registerAction("Playback/Restart") {}
        val entry = TweakRegistry.activeEntries().value.single()

        val duplicateRegistration = TweakRegistry.registerAction("Playback/Restart") {}

        assertSame(entry, TweakRegistry.activeEntries().value.single())

        duplicateRegistration.close()

        assertSame(entry, TweakRegistry.activeEntries().value.single())
        assertEquals(listOf(false, true, false), conflicts)
        observer.close()
    }

    @Test
    fun `unknown and value-backed actions are unavailable for invocation`() {
        TweakRegistry.register(TweakDescriptor("Typography/Size", TweakType.INT, 16))

        val unknown = assertThrows(UnknownTweakActionException::class.java) {
            TweakRegistry.invokeAction("Playback/Missing")
        }
        val value = assertThrows(UnknownTweakActionException::class.java) {
            TweakRegistry.invokeAction("Typography/Size")
        }

        assertEquals(404, unknown.statusCode)
        assertEquals(404, value.statusCode)
    }

    @Test
    fun `action names cannot collide with value tweak names`() {
        val descriptor = TweakDescriptor("Playback/Restart", TweakType.BOOLEAN, true)
        TweakRegistry.register(descriptor)

        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.registerAction(descriptor.name) {}
        }

        assertEquals(descriptor, TweakRegistry.snapshot().single().descriptor)
    }

    @Test
    fun `value tweaks cannot collide with registered action names`() {
        val name = "Playback/Restart"
        TweakRegistry.registerAction(name) {}

        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(TweakDescriptor(name, TweakType.BOOLEAN, true))
        }

        assertEquals(TweakType.ACTION, TweakRegistry.snapshot().single().descriptor.type)
    }

    @Test
    fun `actions reject value patches without changing other tweaks`() {
        val value = TweakDescriptor("Typography/Size", TweakType.INT, 16)
        TweakRegistry.register(value)
        TweakRegistry.registerAction("Playback/Restart") {}

        val error = assertThrows(InvalidTweakValueException::class.java) {
            TweakRegistry.update(
                linkedMapOf(value.name to 20, "Playback/Restart" to "run"),
            )
        }

        assertEquals(422, error.statusCode)
        assertEquals(16, TweakRegistry.snapshot().first().value)
    }

    @Test
    fun `actions reject reset patches without changing other tweaks`() {
        val value = TweakDescriptor("Typography/Size", TweakType.INT, 16)
        TweakRegistry.register(value)
        TweakRegistry.registerAction("Playback/Restart") {}

        val error = assertThrows(InvalidTweakValueException::class.java) {
            TweakRegistry.update(
                linkedMapOf(value.name to 20, "Playback/Restart" to null),
            )
        }

        assertEquals(422, error.statusCode)
        assertEquals(16, TweakRegistry.snapshot().first().value)
    }

    @Test
    fun `actions never remain as adjusted history after their owner leaves`() {
        val registration = TweakRegistry.registerAction("Playback/Restart") {}

        registration.close()

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
    }

    @Test
    fun `closing an old registration cannot remove a newer same-name action`() {
        val previous = TweakRegistry.registerAction("Playback/Restart") {}
        previous.close()
        var invocations = 0
        val replacement = TweakRegistry.registerAction("Playback/Restart") { invocations += 1 }

        previous.close()
        TweakRegistry.invokeAction("Playback/Restart")

        assertEquals(1, invocations)
        assertEquals(SnapOTweakValue.Action(), TweakRegistry.snapshot().single().value)
        replacement.close()
    }

    @Test
    fun `action registrations reject blank stable names`() {
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.registerAction("  ") {}
        }

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `clearing removes actions and their callbacks`() {
        TweakRegistry.registerAction("Playback/Restart") {}

        TweakRegistry.clear()

        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertThrows(UnknownTweakActionException::class.java) {
            TweakRegistry.invokeAction("Playback/Restart")
        }
    }
}

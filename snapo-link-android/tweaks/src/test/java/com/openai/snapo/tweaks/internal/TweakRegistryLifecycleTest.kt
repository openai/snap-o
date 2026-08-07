package com.openai.snapo.tweaks.internal

import androidx.compose.runtime.snapshots.Snapshot
import com.openai.snapo.tweaks.SnapOTweakValue
import com.openai.snapo.tweaks.SnapOTweaks
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
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
    fun `composition registrations reuse the registry-owned state`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle initial composition",
            type = TweakType.INT,
            default = 16,
        )
        val initialState = TweakRegistry.stateFor(descriptor)

        assertTrue(TweakRegistry.snapshot().isEmpty())

        val sharedState = TweakRegistry.register(descriptor)

        assertSame(initialState, sharedState)
        assertEquals(16, initialState.value)

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `looking up registry-owned state does not activate or publish a tweak`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle inactive composition state",
            type = TweakType.INT,
            default = 16,
        )
        var notifications = 0
        val subscription = TweakRegistry.observeChanges { notifications += 1 }
        val initialEntries = TweakRegistry.activeEntries.value

        val state = TweakRegistry.stateFor(descriptor)

        assertEquals(16, state.value)
        assertEquals(0, notifications)
        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertSame(initialEntries, TweakRegistry.activeEntries.value)
        assertTrue(SnapOTweaks.activeTweaks().isEmpty())
        assertTrue(SnapOTweaks.activeTweakEntries().value.isEmpty())

        subscription.close()
    }

    @Test
    fun `state cached by an abandoned snapshot stays absent from active tweaks`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle abandoned composition state",
            type = TweakType.INT,
            default = 16,
        )
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }
        val abandonedSnapshot = Snapshot.takeMutableSnapshot()

        try {
            abandonedSnapshot.enter { TweakRegistry.stateFor(descriptor) }
        } finally {
            abandonedSnapshot.dispose()
        }

        assertEquals(16, TweakRegistry.stateFor(descriptor).value)
        assertEquals(0, notifications)
        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertTrue(TweakRegistry.activeEntries.value.isEmpty())
        assertTrue(SnapOTweaks.activeTweaks().isEmpty())
        assertTrue(SnapOTweaks.activeTweakEntries().value.isEmpty())

        observer.close()
    }

    @Test
    fun `same-name composition registrations each observe shared updates`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle shared composition",
            type = TweakType.INT,
            default = 16,
        )
        val firstState = TweakRegistry.stateFor(descriptor)

        TweakRegistry.register(descriptor)
        TweakRegistry.update(mapOf(descriptor.name to 20))
        val secondState = TweakRegistry.stateFor(descriptor)
        TweakRegistry.register(descriptor)

        assertSame(firstState, secondState)
        assertEquals(20, firstState.value)
        assertEquals(20, secondState.value)

        TweakRegistry.update(mapOf(descriptor.name to 24))

        assertEquals(24, firstState.value)
        assertEquals(24, secondState.value)

        TweakRegistry.unregister(descriptor.name)
        TweakRegistry.update(mapOf(descriptor.name to 28))

        assertEquals(28, secondState.value)

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `a returning tweak restores its last value without remaining active while absent`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle remembered value",
            type = TweakType.INT,
            default = 16,
        )
        val original = TweakRegistry.register(descriptor)
        TweakRegistry.update(mapOf(descriptor.name to 24))

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertTrue(TweakRegistry.activeEntries.value.isEmpty())
        assertSame(original, TweakRegistry.stateFor(descriptor))
        assertEquals(24, TweakRegistry.stateFor(descriptor).value)

        val restored = TweakRegistry.register(descriptor)

        assertSame(original, restored)
        assertEquals(24, restored.value)
        assertEquals(24, TweakRegistry.snapshot().single().value)
    }

    @Test
    fun `expanded snapshots include adjusted inactive tweaks and exclude untouched inactive tweaks`() {
        val untouched = TweakDescriptor("Lifecycle untouched historical tweak", TweakType.INT, 8)
        val adjusted = TweakDescriptor("Lifecycle adjusted historical tweak", TweakType.INT, 16)
        val active = TweakDescriptor("Lifecycle active historical tweak", TweakType.INT, 24)

        TweakRegistry.register(untouched)
        TweakRegistry.unregister(untouched.name)
        TweakRegistry.register(adjusted)
        TweakRegistry.update(mapOf(adjusted.name to 20))
        TweakRegistry.unregister(adjusted.name)
        TweakRegistry.register(active)

        assertEquals(listOf(active.name), TweakRegistry.snapshot().map { it.descriptor.name })
        assertEquals(
            listOf(adjusted.name, active.name),
            TweakRegistry.snapshot(includeAdjusted = true).map { it.descriptor.name },
        )
        assertEquals(20, TweakRegistry.snapshot(includeAdjusted = true).first().value)
    }

    @Test
    fun `unchanged updates do not add inactive tweaks to adjusted history`() {
        val descriptor = TweakDescriptor("Lifecycle unchanged historical tweak", TweakType.INT, 16)

        TweakRegistry.register(descriptor)
        TweakRegistry.update(mapOf(descriptor.name to descriptor.default))
        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
    }

    @Test
    fun `resetting adjusted tweaks retains their historical descriptors and default values`() {
        val descriptor = TweakDescriptor("Lifecycle reset historical tweak", TweakType.INT, 16)

        TweakRegistry.register(descriptor)
        TweakRegistry.update(mapOf(descriptor.name to 24))
        TweakRegistry.update(mapOf(descriptor.name to descriptor.default))
        TweakRegistry.unregister(descriptor.name)

        assertEquals(
            TweakSnapshot(descriptor, descriptor.default, modified = false),
            TweakRegistry.snapshot(includeAdjusted = true).single(),
        )
    }

    @Test
    fun `rejected updates do not create adjusted tweak history`() {
        val descriptor = TweakDescriptor("Lifecycle rejected historical tweak", TweakType.INT, 16)

        TweakRegistry.register(descriptor)
        assertThrows(UnknownTweakException::class.java) {
            TweakRegistry.update(
                linkedMapOf(
                    descriptor.name to 24,
                    "Lifecycle missing historical tweak" to 32,
                ),
            )
        }
        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
    }

    @Test
    fun `expanded snapshots preserve observed order across active and historical tweaks`() {
        val first = TweakDescriptor("Lifecycle first expanded tweak", TweakType.INT, 1)
        val second = TweakDescriptor("Lifecycle second expanded tweak", TweakType.INT, 2)
        val third = TweakDescriptor("Lifecycle third expanded tweak", TweakType.INT, 3)

        TweakRegistry.register(first)
        TweakRegistry.register(second)
        TweakRegistry.register(third)
        TweakRegistry.update(mapOf(first.name to 11, third.name to 33))
        TweakRegistry.unregister(first.name)
        TweakRegistry.unregister(third.name)

        assertEquals(
            listOf(first.name, second.name, third.name),
            TweakRegistry.snapshot(includeAdjusted = true).map { it.descriptor.name },
        )
    }

    @Test
    fun `expanded snapshots retain independently adjusted declarations with the same name`() {
        val original = TweakDescriptor(
            name = "Lifecycle distinct historical declarations",
            type = TweakType.INT,
            default = 16,
            min = 0,
            max = 48,
        )
        val replacement = original.copy(default = 24, max = 64)

        TweakRegistry.register(original)
        TweakRegistry.update(mapOf(original.name to 20))
        TweakRegistry.unregister(original.name)
        TweakRegistry.register(replacement)
        TweakRegistry.update(mapOf(replacement.name to 32))
        TweakRegistry.unregister(replacement.name)

        assertEquals(
            listOf(
                TweakSnapshot(original, 20, modified = true),
                TweakSnapshot(replacement, 32, modified = true),
            ),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
    }

    @Test
    fun `expanded snapshots prioritize active declarations over same-name adjusted history`() {
        val original = TweakDescriptor("Lifecycle replaced historical tweak", TweakType.INT, 16)
        val replacement = original.copy(default = 24)

        TweakRegistry.register(original)
        TweakRegistry.update(mapOf(original.name to 20))
        TweakRegistry.unregister(original.name)
        TweakRegistry.register(replacement)

        assertEquals(
            listOf(
                TweakSnapshot(replacement, replacement.default, modified = false),
                TweakSnapshot(original, 20, modified = true),
            ),
            TweakRegistry.snapshot(includeAdjusted = true),
        )

        TweakRegistry.update(mapOf(replacement.name to 32))
        assertEquals(
            listOf(
                TweakSnapshot(replacement, 32, modified = true),
                TweakSnapshot(original, 20, modified = true),
            ),
            TweakRegistry.snapshot(includeAdjusted = true),
        )

        TweakRegistry.unregister(replacement.name)

        assertEquals(
            listOf(
                TweakSnapshot(original, 20, modified = true),
                TweakSnapshot(replacement, 32, modified = true),
            ),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
    }

    @Test
    fun `resetting same-name adjusted declarations preserves their separate history`() {
        val original = TweakDescriptor("Lifecycle reset shared-name history", TweakType.INT, 16)
        val replacement = original.copy(default = 24)

        TweakRegistry.register(original)
        TweakRegistry.update(mapOf(original.name to 20))
        TweakRegistry.update(mapOf(original.name to original.default))
        TweakRegistry.unregister(original.name)
        TweakRegistry.register(replacement)
        TweakRegistry.update(mapOf(replacement.name to 32))
        TweakRegistry.update(mapOf(replacement.name to replacement.default))
        TweakRegistry.unregister(replacement.name)

        assertEquals(
            listOf(
                TweakSnapshot(original, original.default, modified = false),
                TweakSnapshot(replacement, replacement.default, modified = false),
            ),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
    }

    @Test
    fun `same-name descriptors retain their edited values independently`() {
        val original = TweakDescriptor(
            name = "Lifecycle descriptor-specific values",
            type = TweakType.INT,
            default = 16,
            min = 0,
            max = 48,
        )
        val replacement = original.copy(default = 24, max = 64)
        val originalState = TweakRegistry.register(original)
        TweakRegistry.update(mapOf(original.name to 20))
        TweakRegistry.unregister(original.name)

        val replacementState = TweakRegistry.register(replacement)
        TweakRegistry.update(mapOf(replacement.name to 32))
        TweakRegistry.unregister(replacement.name)

        assertNotSame(originalState, replacementState)
        assertSame(originalState, TweakRegistry.register(original))
        assertEquals(20, originalState.value)
        TweakRegistry.unregister(original.name)
        assertSame(replacementState, TweakRegistry.register(replacement))
        assertEquals(32, replacementState.value)
    }

    @Test
    fun `looking up a replacement descriptor does not reject the outgoing registration`() {
        val outgoing = TweakDescriptor(
            name = "Lifecycle descriptor replacement lookup",
            type = TweakType.INT,
            default = 16,
        )
        val replacement = outgoing.copy(default = 24)
        TweakRegistry.register(outgoing)
        val activeEntries = TweakRegistry.activeEntries.value
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        val replacementState = TweakRegistry.stateFor(replacement)

        assertEquals(24, replacementState.value)
        assertEquals(16, TweakRegistry.snapshot().single().value)
        assertSame(activeEntries, TweakRegistry.activeEntries.value)
        assertEquals(listOf(outgoing.name), SnapOTweaks.activeTweaks().map { it.name })
        assertEquals(0, notifications)

        TweakRegistry.unregister(outgoing.name)

        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertTrue(TweakRegistry.activeEntries.value.isEmpty())
        assertTrue(SnapOTweaks.activeTweaks().isEmpty())
        assertEquals(1, notifications)
        assertSame(replacementState, TweakRegistry.register(replacement))
        assertEquals(24, replacementState.value)
        assertEquals(replacement, TweakRegistry.snapshot().single().descriptor)
        assertEquals(2, notifications)

        observer.close()
    }

    @Test
    fun `cached descriptor values remain available while another same-name descriptor is active`() {
        val original = TweakDescriptor(
            name = "Lifecycle descriptor replacement history",
            type = TweakType.INT,
            default = 16,
        )
        val replacement = original.copy(default = 24)
        TweakRegistry.register(original)
        TweakRegistry.update(mapOf(original.name to 20))
        TweakRegistry.unregister(original.name)
        TweakRegistry.register(replacement)

        assertEquals(20, TweakRegistry.stateFor(original).value)
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(original)
        }
        assertEquals(24, TweakRegistry.snapshot().single().value)
    }

    @Test
    fun `clearing the registry also clears retained tweak values`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle cleared remembered value",
            type = TweakType.INT,
            default = 16,
        )
        val sameNameReplacement = descriptor.copy(default = 24)
        TweakRegistry.register(descriptor)
        TweakRegistry.update(mapOf(descriptor.name to 20))
        TweakRegistry.unregister(descriptor.name)
        TweakRegistry.register(sameNameReplacement)
        TweakRegistry.update(mapOf(sameNameReplacement.name to 32))
        TweakRegistry.unregister(sameNameReplacement.name)

        assertEquals(2, TweakRegistry.snapshot(includeAdjusted = true).size)

        TweakRegistry.clear()

        val replacement = TweakRegistry.stateFor(descriptor)

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
        assertEquals(16, replacement.value)
        assertEquals(24, TweakRegistry.stateFor(sameNameReplacement).value)
        assertSame(replacement, TweakRegistry.register(descriptor))
    }

    @Test
    fun `observable membership changes only when tweaks enter or leave composition`() {
        val descriptor = TweakDescriptor(
            name = "Lifecycle observable membership",
            type = TweakType.INT,
            default = 16,
        )
        val entries = TweakRegistry.activeEntries
        val state = TweakRegistry.register(descriptor)
        val registeredEntries = entries.value
        val entry = registeredEntries.single()

        assertEquals(descriptor.name, entry.name)
        assertEquals(SnapOTweakValue.Integer(16), entry.value.value)

        TweakRegistry.update(mapOf(descriptor.name to 20))

        assertSame(registeredEntries, entries.value)
        assertSame(entry, entries.value.single())
        assertEquals(SnapOTweakValue.Integer(20), entry.value.value)
        assertEquals(20, state.value)

        TweakRegistry.register(descriptor)

        assertSame(registeredEntries, entries.value)

        TweakRegistry.unregister(descriptor.name)

        assertSame(registeredEntries, entries.value)

        TweakRegistry.unregister(descriptor.name)

        assertTrue(entries.value.isEmpty())
    }

    @Test
    fun `temporarily removed tweaks return to their original observed position`() {
        val first = TweakDescriptor("Lifecycle first ordered tweak", TweakType.INT, 1)
        val second = TweakDescriptor("Lifecycle second ordered tweak", TweakType.INT, 2)
        val third = TweakDescriptor("Lifecycle third ordered tweak", TweakType.INT, 3)

        TweakRegistry.register(first)
        TweakRegistry.register(second)
        TweakRegistry.register(third)
        TweakRegistry.unregister(second.name)

        assertEquals(
            listOf(first.name, third.name),
            TweakRegistry.activeEntries.value.map { it.name },
        )

        TweakRegistry.register(second)

        assertEquals(
            listOf(first.name, second.name, third.name),
            TweakRegistry.snapshot().map { it.descriptor.name },
        )
        assertEquals(
            listOf(first.name, second.name, third.name),
            TweakRegistry.activeEntries.value.map { it.name },
        )
    }

    @Test
    fun `observed order survives periods with no active tweaks`() {
        val first = TweakDescriptor("Lifecycle first returning tweak", TweakType.INT, 1)
        val second = TweakDescriptor("Lifecycle second returning tweak", TweakType.INT, 2)

        TweakRegistry.register(first)
        TweakRegistry.register(second)
        TweakRegistry.unregister(first.name)
        TweakRegistry.unregister(second.name)
        TweakRegistry.register(second)
        TweakRegistry.register(first)

        assertEquals(
            listOf(first.name, second.name),
            TweakRegistry.activeEntries.value.map { it.name },
        )
    }

    @Test
    fun `clearing the registry also resets previously observed order`() {
        val first = TweakDescriptor("Lifecycle first reset order", TweakType.INT, 1)
        val second = TweakDescriptor("Lifecycle second reset order", TweakType.INT, 2)

        TweakRegistry.register(first)
        TweakRegistry.register(second)
        TweakRegistry.clear()
        TweakRegistry.register(second)
        TweakRegistry.register(first)

        assertEquals(
            listOf(second.name, first.name),
            TweakRegistry.activeEntries.value.map { it.name },
        )
    }

    @Test
    fun `clearing the registry also clears observable membership`() {
        TweakRegistry.register(
            TweakDescriptor(
                name = "Lifecycle cleared observable membership",
                type = TweakType.INT,
                default = 16,
            ),
        )

        TweakRegistry.clear()

        assertTrue(TweakRegistry.activeEntries.value.isEmpty())
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

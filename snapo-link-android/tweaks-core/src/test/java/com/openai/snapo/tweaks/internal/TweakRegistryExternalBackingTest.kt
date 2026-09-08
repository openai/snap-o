package com.openai.snapo.tweaks.internal

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import com.openai.snapo.tweaks.SnapOTweakValue
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.IdentityHashMap
import java.util.concurrent.atomic.AtomicReference

class TweakRegistryExternalBackingTest {

    private val ownerBackings = IdentityHashMap<State<Any>, ExternalTweakBacking>()

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
        ownerBackings.clear()
    }

    @Test
    fun `external tweaks read and update their application-owned state`() {
        val descriptor = descriptor("External application-owned state")
        val ownerState = mutableStateOf(false)
        val state = register(
            descriptor = descriptor,
            state = ownerState,
            onValueChange = { ownerState.value = it as Boolean },
        )

        assertEquals(false, state.value)
        Snapshot.withMutableSnapshot { ownerState.value = true }
        (state as SelectedTweakState).notifyChanged(ownerBackings.getValue(ownerState))
        assertEquals(true, TweakRegistry.snapshot().single().value)
        assertEquals(
            SnapOTweakValue.Toggle(true),
            TweakRegistry.activeEntries.value.single().value.value,
        )

        TweakRegistry.update(mapOf(descriptor.name to descriptor.default))
        assertEquals(false, ownerState.value)
    }

    @Test
    fun `updates report the effective value written by the application owner`() {
        val descriptor = TweakDescriptor("External clamped value", TweakType.INT, 10)
        val ownerState = mutableStateOf(10)
        register(
            descriptor = descriptor,
            state = ownerState,
            onValueChange = { ownerState.value = (it as Int).coerceAtMost(20) },
        )

        val updated = TweakRegistry.update(mapOf(descriptor.name to 30))

        assertEquals(20, ownerState.value)
        assertEquals(20, updated.single().value)
    }

    @Test
    fun `snapshots report modified state for externally owned values and resets`() {
        val descriptor = descriptor("External modified state")
        val ownerState = mutableStateOf(false)
        register(descriptor, ownerState) { ownerState.value = it as Boolean }

        assertEquals(false, TweakRegistry.snapshot().single().modified)
        val updated = TweakRegistry.update(mapOf(descriptor.name to true)).single()
        assertEquals(true, updated.modified)

        val reset = TweakRegistry.update(mapOf(descriptor.name to null)).single()

        assertEquals(false, ownerState.value)
        assertEquals(false, reset.modified)
    }

    @Test
    fun `unknown reset names fail before changing any registered values`() {
        val descriptor = descriptor("External atomic reset")
        val ownerState = mutableStateOf(true)
        register(descriptor, ownerState) { ownerState.value = it as Boolean }

        assertThrows(UnknownTweakException::class.java) {
            TweakRegistry.update(mapOf(descriptor.name to null, "External missing reset" to null))
        }

        assertEquals(true, ownerState.value)
    }

    @Test
    fun `mixed resets and invalid writes fail before changing any registered values`() {
        val resetDescriptor = descriptor("External mixed reset")
        val updatedDescriptor = descriptor("External mixed update")
        val resetState = mutableStateOf(true)
        val updatedState = mutableStateOf(false)
        register(resetDescriptor, resetState) { resetState.value = it as Boolean }
        register(updatedDescriptor, updatedState) {
            updatedState.value = it as Boolean
        }

        assertThrows(InvalidTweakValueException::class.java) {
            TweakRegistry.update(
                linkedMapOf(resetDescriptor.name to null, updatedDescriptor.name to "invalid"),
            )
        }

        assertEquals(true, resetState.value)
        assertEquals(false, updatedState.value)

        TweakRegistry.unregister(resetDescriptor.name)
        TweakRegistry.unregister(updatedDescriptor.name)

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
    }

    @Test
    fun `failed source writes and resets do not block later batch entries`() {
        val first = descriptor("Settings/First")
        val failing = descriptor("Settings/Unavailable")
        val last = descriptor("Settings/Last")
        val firstOwner = mutableStateOf(false)
        val failingOwner = mutableStateOf(false)
        val lastOwner = mutableStateOf(false)
        register(first, firstOwner) { firstOwner.value = it as Boolean }
        register(failing, failingOwner) { error("Application owner details") }
        register(last, lastOwner) { lastOwner.value = it as Boolean }
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        val updated = applyTweakBatch(
            linkedMapOf(first.name to true, failing.name to true, last.name to true),
        )

        assertEquals(listOf(first.name, last.name), updated.tweaks.map { it.descriptor.name })
        assertEquals(
            listOf(TweakBatchError(failing.name, "The tweak could not be updated.")),
            updated.errors,
        )
        assertEquals(true, firstOwner.value)
        assertEquals(false, failingOwner.value)
        assertEquals(true, lastOwner.value)
        assertEquals(2, notifications)

        val reset = applyTweakBatch(
            linkedMapOf(first.name to null, failing.name to null, last.name to null),
        )

        assertEquals(listOf(first.name, last.name), reset.tweaks.map { it.descriptor.name })
        assertEquals(updated.errors, reset.errors)
        assertEquals(false, firstOwner.value)
        assertEquals(false, lastOwner.value)
        assertEquals(4, notifications)
        observer.close()
        TweakRegistry.unregister(first.name)
        TweakRegistry.unregister(failing.name)
        TweakRegistry.unregister(last.name)
        val history = TweakRegistry.snapshot(includeAdjusted = true)

        assertEquals(listOf(first.name, last.name), history.map { it.descriptor.name })
        assertTrue(history.none(TweakSnapshot::modified))
    }

    @Test
    fun `external owners share the first registration and retain independent lifetimes`() {
        val descriptor = descriptor("External owner identity")
        val firstOwner = mutableStateOf(false)
        val secondOwner = mutableStateOf(false)
        val first = register(descriptor, firstOwner) {
            firstOwner.value = it as Boolean
        }
        val shared = register(descriptor, firstOwner) {
            firstOwner.value = it as Boolean
        }
        val second = register(descriptor, secondOwner) {
            secondOwner.value = it as Boolean
        }

        assertSame(first, shared)
        assertSame(first, second)
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(descriptor)
        }

        TweakRegistry.unregister(descriptor.name, ownerBackings.getValue(secondOwner))
        TweakRegistry.unregister(descriptor.name)
        assertEquals(1, TweakRegistry.snapshot().size)
        TweakRegistry.unregister(descriptor.name)
        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `host writes retain detached immutable snapshots after their owner leaves`() {
        val descriptor = descriptor("External owner lifecycle")
        val ownerState = mutableStateOf(false)
        register(descriptor, ownerState) {
            ownerState.value = it as Boolean
        }
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        TweakRegistry.update(mapOf(descriptor.name to true))
        assertEquals(1, notifications)
        TweakRegistry.unregister(descriptor.name)
        assertEquals(
            listOf(TweakSnapshot(descriptor, true, modified = true)),
            TweakRegistry.snapshot(includeAdjusted = true),
        )

        ownerState.value = false

        assertEquals(
            listOf(TweakSnapshot(descriptor, true, modified = true)),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
        assertThrows(UnknownTweakException::class.java) {
            TweakRegistry.update(mapOf(descriptor.name to false))
        }

        observer.close()
    }

    @Test
    fun `equal external writes still reach the application owner`() {
        val descriptor = descriptor("External equal value")
        val ownerState = mutableStateOf(false)
        var writes = 0
        register(descriptor, ownerState) {
            writes += 1
            ownerState.value = it as Boolean
        }

        val snapshot = TweakRegistry.update(mapOf(descriptor.name to false)).single()

        assertEquals(1, writes)
        assertEquals(false, snapshot.value)
        assertEquals(false, snapshot.modified)

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
    }

    @Test
    fun `owner modification status publishes even when the effective value does not change`() {
        val name = "External override matching upstream"
        val override = mutableStateOf<Boolean?>(null)
        val state = object : State<Any> {
            override val value: Any
                get() = override.value ?: false
        }
        var writes = 0
        var resets = 0
        TweakRegistry.register(
            backing(
                name = name,
                state = state,
                descriptorFactory = { descriptor(name) },
                onValueChange = {
                    writes += 1
                    override.value = it as Boolean
                },
                onReset = {
                    resets += 1
                    override.value = null
                },
                isModified = { override.value != null },
            ),
        )
        val entry = TweakRegistry.activeEntries.value.single()
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        assertEquals(false, entry.modified.value)

        val updated = TweakRegistry.update(mapOf(name to false)).single()

        assertEquals(1, writes)
        assertEquals(false, updated.value)
        assertEquals(true, updated.modified)
        assertEquals(true, entry.modified.value)
        assertEquals(1, notifications)

        val reset = TweakRegistry.update(mapOf(name to null)).single()

        assertEquals(1, resets)
        assertEquals(false, reset.value)
        assertEquals(false, reset.modified)
        assertEquals(false, entry.modified.value)
        assertEquals(2, notifications)
        TweakRegistry.unregister(name)
        assertEquals(
            listOf(TweakSnapshot(descriptor(name), false, modified = false)),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
        observer.close()
    }

    @Test
    fun `owner resets restore the current upstream value instead of the captured default`() {
        val name = "External dynamic upstream"
        val upstream = mutableStateOf(false)
        val override = mutableStateOf<Boolean?>(null)
        val state = object : State<Any> {
            override val value: Any
                get() = override.value ?: upstream.value
        }
        TweakRegistry.register(
            backing(
                name = name,
                state = state,
                descriptorFactory = { descriptor(name, state.value as Boolean) },
                onValueChange = { override.value = it as Boolean },
                onReset = { override.value = null },
                isModified = { override.value != null },
            ),
        )
        val initial = TweakRegistry.snapshot().single()
        TweakRegistry.update(mapOf(name to true))
        upstream.value = true

        val reset = TweakRegistry.update(mapOf(name to null)).single()

        assertEquals(false, initial.descriptor.default)
        assertEquals(true, reset.value)
        assertEquals(false, reset.modified)
        assertEquals(null, override.value)

        TweakRegistry.unregister(name)
        upstream.value = false

        assertEquals(
            listOf(TweakSnapshot(initial.descriptor, true, modified = false)),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
    }

    @Test
    fun `lazy registrations and active entry membership never evaluate their owner`() {
        val name = "External lazy registration"
        val backing = CountingBacking(false)

        val first = register(name, backing)
        val shared = register(name, backing)

        assertSame(first, shared)
        val entries = TweakRegistry.activeEntries.value
        assertEquals(listOf(name), entries.map { it.name })
        assertSame(entries.single().modified, entries.single().modified)
        assertEquals(0, backing.reads)

        TweakRegistry.unregister(name)
        TweakRegistry.unregister(name)
        assertTrue(TweakRegistry.activeEntries.value.isEmpty())
        assertEquals(0, backing.reads)
        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
        assertEquals(0, backing.reads)
    }

    @Test
    fun `the first lazy snapshot shares one owner read with its descriptor`() {
        val name = "External lazy snapshot"
        val backing = CountingBacking(false)
        val selected = register(name, backing) as SelectedTweakState

        val snapshot = TweakRegistry.snapshot().single()

        assertEquals(false, snapshot.descriptor.default)
        assertEquals(false, snapshot.value)
        assertEquals(1, backing.reads)

        backing.current = true
        selected.notifyChanged(backing)
        assertEquals(true, TweakRegistry.snapshot().single().value)
        assertEquals(2, backing.reads)
    }

    @Test
    fun `cold cached snapshots do not access owner values or modification status`() {
        val backing = CountingBacking(false)
        val selected = register("External cold cached snapshot", backing) as SelectedTweakState

        assertThrows(UninitializedTweakSnapshotException::class.java) {
            TweakRegistry.snapshot(cachedOnly = true)
        }
        selected.notifyChanged(backing)

        assertEquals(0, backing.reads)
        assertEquals(0, backing.statusReads)
    }

    @Test
    fun `warm cached snapshots can be read on workers without accessing their owners`() {
        val backing = CountingBacking(false)
        register("External warm worker snapshot", backing)
        val initial = TweakRegistry.snapshot()
        val workerSnapshot = AtomicReference<List<TweakSnapshot>>()

        val worker = Thread {
            workerSnapshot.set(TweakRegistry.snapshot(cachedOnly = true))
        }
        worker.start()
        worker.join()

        assertEquals(initial, workerSnapshot.get())
        assertEquals(1, backing.reads)
        assertEquals(1, backing.statusReads)
    }

    @Test
    fun `selected owner notifications refresh cached values and modification status`() {
        val backing = CountingBacking(false)
        val selected = register("External mirrored owner status", backing) as SelectedTweakState
        TweakRegistry.snapshot()
        backing.current = true

        selected.notifyChanged(backing)

        val updated = TweakRegistry.snapshot(cachedOnly = true).single()
        assertEquals(true, updated.value)
        assertEquals(true, updated.modified)
        assertEquals(2, backing.reads)
        assertEquals(2, backing.statusReads)
    }

    @Test
    fun `promotion immediately refreshes a previously initialized owner mirror`() {
        val name = "External mirrored owner promotion"
        val first = CountingBacking(false)
        val second = CountingBacking(true)
        val selected = register(name, first)
        register(name, second)
        TweakRegistry.snapshot()

        TweakRegistry.unregister(name, first)

        assertEquals(true, selected.value)
        assertEquals(true, TweakRegistry.snapshot(cachedOnly = true).single().value)
        assertEquals(1, first.reads)
        assertEquals(1, second.reads)
    }

    @Test
    fun `distinct lazy owners share their first registration without evaluating either owner`() {
        val name = "External lazy sharing"
        val first = CountingBacking(false)
        val second = CountingBacking(false)
        val firstState = register(name, first)
        val secondState = register(name, second)

        assertSame(firstState, secondState)

        assertEquals(0, first.reads)
        assertEquals(0, second.reads)
    }

    @Test
    fun `owner change notifications follow the selected backing without reading values`() {
        val name = "External observed owner selection"
        val first = CountingBacking(false)
        val second = CountingBacking(true)
        val selected = register(name, first) as SelectedTweakState
        register(name, second)
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        assertTrue(selected.isSelected(first))
        assertEquals(false, selected.isSelected(second))
        selected.notifyChanged(second)
        assertEquals(0, notifications)

        selected.notifyChanged(first)
        assertEquals(1, notifications)

        TweakRegistry.unregister(name, first)
        assertEquals(2, notifications)
        assertEquals(false, selected.isSelected(first))
        assertTrue(selected.isSelected(second))

        selected.notifyChanged(first)
        assertEquals(2, notifications)
        selected.notifyChanged(second)
        assertEquals(3, notifications)

        TweakRegistry.unregister(name, second)
        assertEquals(4, notifications)
        selected.notifyChanged(second)
        assertEquals(4, notifications)
        assertEquals(0, first.reads)
        assertEquals(0, second.reads)
        observer.close()
    }

    @Test
    fun `removing the selected owner promotes the next backing and its callbacks`() {
        val name = "External owner promotion"
        val descriptor = descriptor(name)
        val firstOwner = mutableStateOf(false)
        val secondOwner = mutableStateOf(true)
        var firstWrites = 0
        var secondWrites = 0
        val first = register(descriptor, firstOwner) {
            firstWrites += 1
            firstOwner.value = it as Boolean
        }
        val shared = register(descriptor, secondOwner) {
            secondWrites += 1
            secondOwner.value = it as Boolean
        }
        val entry = TweakRegistry.activeEntries.value.single()

        assertSame(first, shared)
        assertEquals(false, shared.value)
        assertEquals(false, entry.modified.value)

        TweakRegistry.update(mapOf(name to true))

        assertEquals(1, firstWrites)
        assertEquals(0, secondWrites)
        assertEquals(true, firstOwner.value)
        assertEquals(true, entry.modified.value)

        TweakRegistry.update(mapOf(name to null))

        assertEquals(2, firstWrites)
        assertEquals(0, secondWrites)
        assertEquals(false, firstOwner.value)
        assertEquals(false, entry.modified.value)

        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        TweakRegistry.unregister(name, ownerBackings.getValue(firstOwner))

        assertEquals(1, notifications)
        assertEquals(true, first.value)
        assertEquals(true, shared.value)
        assertEquals(true, entry.modified.value)
        assertEquals(false, TweakRegistry.snapshot().single().descriptor.default)

        TweakRegistry.update(mapOf(name to false))

        assertEquals(2, firstWrites)
        assertEquals(1, secondWrites)
        assertEquals(false, secondOwner.value)
        assertEquals(false, entry.modified.value)

        TweakRegistry.update(mapOf(name to null))

        assertEquals(2, secondWrites)
        assertEquals(2, firstWrites)

        TweakRegistry.unregister(name, ownerBackings.getValue(secondOwner))

        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertEquals(
            listOf(TweakSnapshot(descriptor, false, modified = false)),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
        observer.close()
    }

    @Test
    fun `returning untouched owners do not replace their prior adjusted snapshot`() {
        val descriptor = descriptor("External returning history")
        val original = mutableStateOf(false)
        register(descriptor, original) { original.value = it as Boolean }
        TweakRegistry.update(mapOf(descriptor.name to true))
        TweakRegistry.unregister(descriptor.name)

        val replacement = mutableStateOf(false)
        register(descriptor, replacement) { replacement.value = it as Boolean }

        assertEquals(
            listOf(TweakSnapshot(descriptor, false, modified = false)),
            TweakRegistry.snapshot(includeAdjusted = true),
        )

        TweakRegistry.unregister(descriptor.name)

        assertEquals(
            listOf(TweakSnapshot(descriptor, true, modified = true)),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
    }

    @Test
    fun `owner and registry histories preserve same-name declarations independently`() {
        val owned = descriptor("External mixed declaration history")
        TweakRegistry.register(owned)
        TweakRegistry.update(mapOf(owned.name to true))
        TweakRegistry.unregister(owned.name)

        val ownerDescriptor = descriptor(owned.name, default = true)
        val owner = mutableStateOf(true)
        register(ownerDescriptor, owner) { owner.value = it as Boolean }
        TweakRegistry.update(mapOf(ownerDescriptor.name to false))

        assertEquals(
            listOf(
                TweakSnapshot(ownerDescriptor, false, modified = true),
                TweakSnapshot(owned, true, modified = true),
            ),
            TweakRegistry.snapshot(includeAdjusted = true),
        )

        TweakRegistry.unregister(ownerDescriptor.name)

        assertEquals(
            listOf(
                TweakSnapshot(owned, true, modified = true),
                TweakSnapshot(ownerDescriptor, false, modified = true),
            ),
            TweakRegistry.snapshot(includeAdjusted = true),
        )
    }

    @Test
    fun `clearing the registry discards detached owner history`() {
        val descriptor = descriptor("External cleared history")
        val owner = mutableStateOf(false)
        register(descriptor, owner) { owner.value = it as Boolean }
        TweakRegistry.update(mapOf(descriptor.name to true))
        TweakRegistry.unregister(descriptor.name)

        assertEquals(1, TweakRegistry.snapshot(includeAdjusted = true).size)

        TweakRegistry.clear()

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
    }

    @Test
    fun `removing a secondary owner preserves the primary without publishing`() {
        val name = "External secondary owner removal"
        val first = CountingBacking(false)
        val second = CountingBacking(true)
        register(name, first)
        register(name, second)
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        TweakRegistry.unregister(name, second)

        assertEquals(0, notifications)
        assertEquals(0, first.reads)
        assertEquals(0, second.reads)
        assertEquals(false, TweakRegistry.snapshot().single().value)

        TweakRegistry.unregister(name, first)

        assertEquals(1, notifications)
        assertTrue(TweakRegistry.snapshot().isEmpty())
        observer.close()
    }

    @Test
    fun `promotion before first observation captures the surviving owners default`() {
        val name = "External unobserved owner promotion"
        val first = CountingBacking(false)
        val second = CountingBacking(true)
        register(name, first)
        register(name, second)

        TweakRegistry.unregister(name, first)

        assertEquals(0, first.reads)
        assertEquals(0, second.reads)

        val snapshot = TweakRegistry.snapshot().single()

        assertEquals(true, snapshot.descriptor.default)
        assertEquals(true, snapshot.value)
        assertEquals(0, first.reads)
        assertEquals(1, second.reads)
    }

    @Test
    fun `actions reject conflicting lazy owners without evaluating them`() {
        val name = "Settings/Conflicting action"
        val owner = CountingBacking(false)
        val action = TweakRegistry.registerAction(name) {}

        assertThrows(IllegalArgumentException::class.java) {
            register(name, owner)
        }

        assertEquals(0, owner.reads)
        action.close()
    }

    private fun register(name: String, backing: CountingBacking): State<Any> {
        backing.name = name
        return TweakRegistry.register(backing)
    }

    private fun register(
        descriptor: TweakDescriptor,
        state: State<Any>,
        onValueChange: (Any) -> Unit,
    ): State<Any> {
        val backing = backing(
            name = descriptor.name,
            state = state,
            descriptorFactory = { descriptor },
            onValueChange = onValueChange,
            onReset = { onValueChange(descriptor.default) },
            isModified = { state.value != descriptor.default },
        )
        ownerBackings[state] = backing
        return TweakRegistry.register(backing)
    }

    private fun backing(
        name: String,
        state: State<Any>,
        descriptorFactory: () -> TweakDescriptor,
        onValueChange: (Any) -> Unit,
        onReset: () -> Unit,
        isModified: () -> Boolean,
    ): ExternalTweakBacking {
        val updateOwner = onValueChange
        val resetOwner = onReset
        val ownerModified = isModified
        return object : ExternalTweakBacking {
            override val name: String = name
            override val descriptor: TweakDescriptor by lazy(descriptorFactory)
            override val value: Any
                get() = state.value

            override fun onValueChange(value: Any) = updateOwner(value)

            override fun onReset() = resetOwner()

            override fun isModified(): Boolean = ownerModified()
        }
    }

    private fun descriptor(name: String, default: Boolean = false) = TweakDescriptor(
        name = name,
        type = TweakType.BOOLEAN,
        default = default,
    )

    private class CountingBacking(initialValue: Boolean) : ExternalTweakBacking {
        override lateinit var name: String
        override val descriptor: TweakDescriptor by lazy {
            TweakDescriptor(name, TweakType.BOOLEAN, initial)
        }
        var reads = 0
        var statusReads = 0
        var current = initialValue
        val initial: Boolean by lazy {
            reads += 1
            current
        }
        private var initialValuePending = true

        override val value: Any
            get() = if (initialValuePending) {
                initialValuePending = false
                initial
            } else {
                reads += 1
                current
            }

        override fun onValueChange(value: Any) {
            current = value as Boolean
        }

        override fun onReset() {
            current = initial
        }

        override fun isModified(): Boolean = (current != initial).also { statusReads += 1 }
    }
}

package com.openai.snapo.tweaks.internal

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakChangePublisherTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `subscription begins with the complete current snapshot`() {
        TweakRegistry.register(descriptor("Typography/Size", 16))
        val publisher = TweakChangePublisher { true }

        publisher.subscribe().use { subscription ->
            assertEquals(listOf("Typography/Size"), subscription.initial.names())
            assertNull(subscription.events.poll())
        }
    }

    @Test
    fun `cold cached subscriptions fail without retaining a subscriber or reading owners`() {
        var reads = 0
        val owner = object : State<Any> {
            override val value: Any
                get() = false.also { reads += 1 }
        }
        TweakRegistry.register(booleanBacking("Settings/Cold cached hints", owner))
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher(
            schedule = { runnable -> scheduled.add(runnable) },
            snapshot = { TweakRegistry.snapshot(cachedOnly = true) },
        )

        assertThrows(UninitializedTweakSnapshotException::class.java) {
            publisher.subscribe()
        }
        publisher.notifyChanged()

        assertEquals(0, reads)
        assertTrue(scheduled.isEmpty())

        TweakRegistry.snapshot()
        publisher.subscribe().use { subscription ->
            assertEquals(false, subscription.initial.single().value)
        }
        assertEquals(1, reads)
    }

    @Test
    fun `lazy tweak registrations wait for scheduled publication`() {
        var reads = 0
        val initialValue = lazy {
            reads += 1
            false
        }
        val state = object : State<Any> {
            override val value: Any
                get() = initialValue.value
        }
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            TweakRegistry.register(
                booleanBacking(
                    name = "Settings/Show hints later",
                    owner = state,
                    descriptorFactory = {
                        TweakDescriptor(
                            "Settings/Show hints later",
                            TweakType.BOOLEAN,
                            initialValue.value,
                        )
                    },
                ),
            )

            assertEquals(0, reads)
            assertEquals(1, scheduled.size)

            scheduled.single().run()

            assertEquals(1, reads)
            assertEquals(false, subscription.events.poll()?.single()?.value)
        }

        observer.close()
    }

    @Test
    fun `composition changes are published together after the scheduled turn`() {
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            TweakRegistry.register(descriptor("Motion/Duration", 400))
            TweakRegistry.register(descriptor("Motion/Delay", 100))
            TweakRegistry.register(descriptor("Motion/Repeat", 2))

            assertEquals(1, scheduled.size)
            assertNull(subscription.events.poll())

            scheduled.removeAt(0).run()

            assertEquals(
                listOf("Motion/Duration", "Motion/Delay", "Motion/Repeat"),
                subscription.events.poll()?.names(),
            )
            assertTrue(scheduled.isEmpty())
            assertNull(subscription.events.poll())
        }

        observer.close()
    }

    @Test
    fun `added and removed tweaks are reconciled in one snapshot`() {
        TweakRegistry.register(descriptor("Motion/Old", 100))
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            TweakRegistry.unregister("Motion/Old")
            TweakRegistry.register(descriptor("Motion/New", 200))

            assertEquals(1, scheduled.size)
            scheduled.single().run()

            assertEquals(listOf("Motion/New"), subscription.events.poll()?.names())
        }

        observer.close()
    }

    @Test
    fun `value changes appear in the streamed snapshot`() {
        TweakRegistry.register(descriptor("Motion/Duration", 400))
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            TweakRegistry.update(mapOf("Motion/Duration" to 550))
            scheduled.single().run()

            assertEquals(550, subscription.events.poll()?.single()?.value)
        }

        observer.close()
    }

    @Test
    fun `changes arriving during publication are eventually published`() {
        val tweak = descriptor("Motion/Duration", 400)
        TweakRegistry.register(tweak)
        val scheduled = mutableListOf<Runnable>()
        var updateOnNextSnapshot = false
        var updatedDuringPublication = false
        val publisher = TweakChangePublisher(
            schedule = { runnable -> scheduled.add(runnable) },
            snapshot = {
                val current = TweakRegistry.snapshot()
                if (updateOnNextSnapshot) {
                    updateOnNextSnapshot = false
                    TweakRegistry.update(mapOf(tweak.name to 550))
                    updatedDuringPublication = true
                }
                current
            },
        )
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            TweakRegistry.update(mapOf(tweak.name to 500))
            updateOnNextSnapshot = true

            assertEquals(1, scheduled.size)
            scheduled.removeAt(0).run()

            assertTrue(updatedDuringPublication)
            assertEquals(500, subscription.events.poll()?.single()?.value)
            assertEquals(1, scheduled.size)

            scheduled.removeAt(0).run()

            assertEquals(550, subscription.events.poll()?.single()?.value)
            assertTrue(scheduled.isEmpty())
            assertNull(subscription.events.poll())
        }

        observer.close()
    }

    @Test
    fun `changes during publication survive subscriber churn`() {
        val tweak = descriptor("Motion/Duration", 400)
        TweakRegistry.register(tweak)
        val scheduled = mutableListOf<Runnable>()
        var churnOnNextSnapshot = false
        lateinit var publisher: TweakChangePublisher
        lateinit var initialSubscription: TweakChangePublisher.Subscription
        var replacementSubscription: TweakChangePublisher.Subscription? = null
        publisher = TweakChangePublisher(
            schedule = { runnable -> scheduled.add(runnable) },
            snapshot = {
                val current = TweakRegistry.snapshot()
                if (churnOnNextSnapshot) {
                    churnOnNextSnapshot = false
                    initialSubscription.close()
                    TweakRegistry.update(mapOf(tweak.name to 550))
                    replacementSubscription = publisher.subscribe()
                }
                current
            },
        )
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)
        initialSubscription = publisher.subscribe()

        try {
            TweakRegistry.update(mapOf(tweak.name to 500))
            churnOnNextSnapshot = true

            scheduled.removeAt(0).run()

            val replacement = requireNotNull(replacementSubscription)
            assertEquals(550, replacement.initial.single().value)
            assertEquals(1, scheduled.size)

            scheduled.removeAt(0).run()

            assertEquals(550, replacement.events.poll()?.single()?.value)
            assertTrue(scheduled.isEmpty())
            assertNull(replacement.events.poll())
        } finally {
            initialSubscription.close()
            replacementSubscription?.close()
            observer.close()
        }
    }

    @Test
    fun `reference count changes and unchanged values do not publish`() {
        val tweak = descriptor("Motion/Duration", 400)
        TweakRegistry.register(tweak)
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use {
            TweakRegistry.register(tweak)
            TweakRegistry.unregister(tweak.name)
            TweakRegistry.update(mapOf(tweak.name to 400))

            assertTrue(scheduled.isEmpty())
        }

        observer.close()
    }

    @Test
    fun `slow subscribers keep only the latest complete snapshot`() {
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            TweakRegistry.register(descriptor("Motion/First", 1))
            scheduled.removeAt(0).run()
            TweakRegistry.register(descriptor("Motion/Second", 2))
            scheduled.removeAt(0).run()

            assertEquals(
                listOf("Motion/First", "Motion/Second"),
                subscription.events.poll()?.names(),
            )
            assertNull(subscription.events.poll())
        }

        observer.close()
    }

    @Test
    fun `selected owner flow emissions publish external values and override status`() = runBlocking {
        var current = false
        var modified = false
        var reads = 0
        val owner = object : State<Any> {
            override val value: Any
                get() = current.also { reads += 1 }
        }
        val backing = booleanBacking(
            name = "Settings/Observable hints",
            owner = owner,
            modified = { modified },
        )
        val selected = TweakRegistry.register(backing) as SelectedTweakState
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)
        assertEquals(0, reads)

        publisher.subscribe().use { subscription ->
            assertEquals(1, reads)
            current = true
            assertTrue(scheduled.isEmpty())

            flowOf(Unit).collect { selected.notifyChanged(backing) }
            scheduled.removeAt(0).run()

            val update = requireNotNull(subscription.events.poll()).single()
            assertEquals(true, update.value)
            assertEquals(false, update.modified)

            modified = true
            flowOf(Unit).collect { selected.notifyChanged(backing) }
            scheduled.removeAt(0).run()

            val statusOnly = requireNotNull(subscription.events.poll()).single()
            assertEquals(true, statusOnly.value)
            assertEquals(true, statusOnly.modified)
        }

        val readsAfterClose = reads
        current = false
        flowOf(Unit).collect { selected.notifyChanged(backing) }
        assertEquals(readsAfterClose + 1, reads)
        assertEquals(false, TweakRegistry.snapshot(cachedOnly = true).single().value)
        assertTrue(scheduled.isEmpty())
        observer.close()
    }

    @Test
    fun `queued publications do not read owners after the last subscriber leaves`() {
        var reads = 0
        val owner = object : State<Any> {
            override val value: Any
                get() = false.also { reads += 1 }
        }
        TweakRegistry.register(booleanBacking("Settings/Queued hints", owner))
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val subscription = publisher.subscribe()

        publisher.notifyChanged()
        subscription.close()
        scheduled.removeAt(0).run()

        assertEquals(1, reads)
        assertTrue(scheduled.isEmpty())
    }

    @Test
    fun `unrelated compose state changes do not publish tweak snapshots`() {
        TweakRegistry.register(descriptor("Motion/Duration", 400))
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)
        val unrelatedState = mutableStateOf(0)

        publisher.subscribe().use { subscription ->
            Snapshot.withMutableSnapshot {
                unrelatedState.value = 1
            }

            assertTrue(scheduled.isEmpty())

            TweakRegistry.update(mapOf("Motion/Duration" to 550))
            scheduled.single().run()

            assertEquals(550, subscription.events.poll()?.single()?.value)
        }

        observer.close()
    }

    private fun descriptor(name: String, default: Int) = TweakDescriptor(
        name = name,
        type = TweakType.INT,
        default = default,
    )

    private fun booleanBacking(
        name: String,
        owner: State<Any>,
        modified: () -> Boolean = { false },
        descriptorFactory: () -> TweakDescriptor = {
            TweakDescriptor(name, TweakType.BOOLEAN, false)
        },
    ): ExternalTweakBacking = object : ExternalTweakBacking {
        override val name: String = name
        override val descriptor: TweakDescriptor by lazy(descriptorFactory)
        override val value: Any
            get() = owner.value

        override fun onValueChange(value: Any) = Unit

        override fun onReset() = Unit

        override fun isModified(): Boolean = modified()
    }

    private fun List<TweakSnapshot>.names(): List<String> = map { it.descriptor.name }
}

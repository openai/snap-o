package com.openai.snapo.tweaks.internal

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    private fun List<TweakSnapshot>.names(): List<String> = map { it.descriptor.name }
}

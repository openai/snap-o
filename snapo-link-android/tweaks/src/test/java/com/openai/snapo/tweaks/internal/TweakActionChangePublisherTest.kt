package com.openai.snapo.tweaks.internal

import com.openai.snapo.tweaks.SnapOTweakValue
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakActionChangePublisherTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `initial action events include every active value and action descriptor`() {
        val value = TweakDescriptor("Motion/Duration", TweakType.INT, 400)
        TweakRegistry.register(value)
        val registration = TweakRegistry.registerAction("Playback/Restart") {}
        val publisher = TweakChangePublisher { true }

        publisher.subscribe().use { subscription ->
            assertEquals(
                listOf("Motion/Duration", "Playback/Restart"),
                subscription.initial.map { it.descriptor.name },
            )
            assertEquals(TweakType.INT, subscription.initial[0].descriptor.type)
            assertEquals(400, subscription.initial[0].value)
            assertEquals(TweakType.ACTION, subscription.initial[1].descriptor.type)
            assertEquals(SnapOTweakValue.Action(), subscription.initial[1].value)
            assertNull(subscription.events.poll())
        }

        registration.close()
        publisher.close()
    }

    @Test
    fun `live conflict and recovery replace the complete streamed action snapshot`() {
        val original = TweakRegistry.registerAction("Playback/Restart") {}
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            assertEquals(SnapOTweakValue.Action(), subscription.initial.single().value)

            val duplicate = TweakRegistry.registerAction("Playback/Restart") {}

            assertEquals(1, scheduled.size)
            scheduled.removeAt(0).run()

            val conflicted = subscription.events.poll()?.single()
            assertEquals("Playback/Restart", conflicted?.descriptor?.name)
            assertEquals(TweakType.ACTION, conflicted?.descriptor?.type)
            assertEquals(SnapOTweakValue.Action(conflicted = true), conflicted?.value)
            assertNull(subscription.events.poll())

            duplicate.close()

            assertEquals(1, scheduled.size)
            scheduled.removeAt(0).run()

            val recovered = subscription.events.poll()?.single()
            assertEquals("Playback/Restart", recovered?.descriptor?.name)
            assertEquals(SnapOTweakValue.Action(), recovered?.value)
            assertNull(subscription.events.poll())
        }

        observer.close()
        original.close()
        publisher.close()
    }

    @Test
    fun `action registration and disposal publish complete value-preserving snapshots`() {
        val value = TweakDescriptor("Motion/Duration", TweakType.INT, 400)
        TweakRegistry.register(value)
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            val registration = TweakRegistry.registerAction("Playback/Restart") {}
            TweakRegistry.update(mapOf(value.name to 550))

            assertEquals(1, scheduled.size)
            scheduled.removeAt(0).run()

            val added = requireNotNull(subscription.events.poll())
            assertEquals(listOf(value.name, "Playback/Restart"), added.map { it.descriptor.name })
            assertEquals(550, added[0].value)
            assertEquals(TweakType.ACTION, added[1].descriptor.type)
            assertNull(subscription.events.poll())

            registration.close()

            assertEquals(1, scheduled.size)
            scheduled.removeAt(0).run()

            val removed = requireNotNull(subscription.events.poll())
            assertEquals(listOf(value.name), removed.map { it.descriptor.name })
            assertEquals(550, removed.single().value)
            assertNull(subscription.events.poll())
        }

        observer.close()
        publisher.close()
    }

    @Test
    fun `invoking an action without registry changes does not publish a new snapshot`() {
        var invocations = 0
        val registration = TweakRegistry.registerAction("Playback/Restart") { invocations += 1 }
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            TweakRegistry.invokeAction("Playback/Restart")

            assertEquals(1, invocations)
            assertTrue(scheduled.isEmpty())
            assertNull(subscription.events.poll())
        }

        observer.close()
        registration.close()
        publisher.close()
    }
}

package com.openai.snapo.tweaks.internal

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakBatchUpdateTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `valid values survive invalid missing action and enum entries`() {
        val size = TweakDescriptor("Typography/Size", TweakType.INT, 16)
        val enabled = TweakDescriptor("Motion/Enabled", TweakType.BOOLEAN, false)
        val duration = TweakDescriptor("Motion/Duration", TweakType.INT, 400)
        val appearance = TweakDescriptor(
            name = "Appearance/Theme",
            type = TweakType.ENUM,
            default = "System",
            options = listOf("System", "Dark"),
        )
        val sizeState = TweakRegistry.register(size)
        val enabledState = TweakRegistry.register(enabled)
        val durationState = TweakRegistry.register(duration)
        val appearanceState = TweakRegistry.register(appearance)
        TweakRegistry.registerAction("Playback/Restart") {}

        val result = applyTweakBatch(
            linkedMapOf(
                size.name to 20,
                enabled.name to "invalid",
                "Missing/Value" to true,
                "Playback/Restart" to true,
                appearance.name to "Stale",
                duration.name to 500,
            ),
        )

        assertEquals(listOf(size.name, duration.name), result.tweaks.map { it.descriptor.name })
        assertEquals(
            listOf(enabled.name, "Missing/Value", "Playback/Restart", appearance.name),
            result.errors.map(TweakBatchError::name),
        )
        assertTrue(result.errors.all { it.error.isNotBlank() })
        assertEquals(20, sizeState.value)
        assertEquals(false, enabledState.value)
        assertEquals(500, durationState.value)
        assertEquals("System", appearanceState.value)
    }

    @Test
    fun `all failed values return errors without mutating active tweaks`() {
        val descriptor = TweakDescriptor("Motion/Enabled", TweakType.BOOLEAN, false)
        val state = TweakRegistry.register(descriptor)

        val result = applyTweakBatch(
            linkedMapOf(
                descriptor.name to "invalid",
                "Missing/Value" to true,
            ),
        )

        assertTrue(result.tweaks.isEmpty())
        assertEquals(
            listOf(
                "Invalid value for Motion/Enabled: Expected a boolean.",
                "Unknown tweak: Missing/Value",
            ),
            result.errors.map(TweakBatchError::error),
        )
        assertEquals(false, state.value)

        TweakRegistry.unregister(descriptor.name)

        assertTrue(TweakRegistry.snapshot(includeAdjusted = true).isEmpty())
    }

    @Test
    fun `successful entries preserve adjusted history and coalesce publications`() {
        val size = TweakDescriptor("Typography/Size", TweakType.INT, 16)
        val duration = TweakDescriptor("Motion/Duration", TweakType.INT, 400)
        TweakRegistry.register(size)
        TweakRegistry.register(duration)
        val scheduled = mutableListOf<Runnable>()
        val publisher = TweakChangePublisher { runnable -> scheduled.add(runnable) }
        val observer = TweakRegistry.observeChanges(publisher::notifyChanged)

        publisher.subscribe().use { subscription ->
            val result = applyTweakBatch(
                linkedMapOf(
                    size.name to 20,
                    "Missing/Value" to true,
                    duration.name to 500,
                ),
            )

            assertEquals(2, result.tweaks.size)
            assertEquals(1, result.errors.size)
            assertEquals(1, scheduled.size)

            scheduled.single().run()

            assertEquals(
                listOf(20, 500),
                subscription.events.poll()?.map(TweakSnapshot::value),
            )
        }

        observer.close()
        publisher.close()
        TweakRegistry.unregister(size.name)
        TweakRegistry.unregister(duration.name)

        assertEquals(
            listOf(20, 500),
            TweakRegistry.snapshot(includeAdjusted = true).map(TweakSnapshot::value),
        )
    }

    @Test
    fun `unexpected owner failures are sanitized and do not stop later entries`() {
        val size = TweakDescriptor("Typography/Size", TweakType.INT, 16)
        val duration = TweakDescriptor("Motion/Duration", TweakType.INT, 400)
        TweakRegistry.register(size)
        TweakRegistry.register(duration)

        val result = applyTweakBatch(
            linkedMapOf(
                size.name to 20,
                "Settings/Unavailable" to true,
                duration.name to 500,
            ),
            update = { values ->
                if (values.containsKey("Settings/Unavailable")) {
                    error("Application owner details")
                }
                TweakRegistry.update(values)
            },
        )

        assertEquals(listOf(size.name, duration.name), result.tweaks.map { it.descriptor.name })
        assertEquals(
            listOf(TweakBatchError("Settings/Unavailable", "The tweak could not be updated.")),
            result.errors,
        )
    }

    @Test
    fun `successful unchanged values remain in the response without errors`() {
        val descriptor = TweakDescriptor("Motion/Enabled", TweakType.BOOLEAN, false)
        TweakRegistry.register(descriptor)

        val result = applyTweakBatch(mapOf(descriptor.name to false))

        assertEquals(false, result.tweaks.single().value)
        assertTrue(result.errors.isEmpty())
    }

    @Test
    fun `empty batches have no values or errors`() {
        val result = applyTweakBatch(emptyMap())

        assertTrue(result.tweaks.isEmpty())
        assertTrue(result.errors.isEmpty())
    }
}

package com.openai.snapo.tweaks

import androidx.compose.runtime.mutableStateOf
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ExternalEnumTweakTest {
    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `external enum sources expose ordered selections without eager or duplicate reads`() {
        var reads = 0
        val binding = testTweakBinding(
            "External enum",
            testTweakSource(read = {
                reads++
                SpecializedPreviewMode.Automatic
            }),
        )
        val registration = TweakRegistration(binding)
        registration.onRemembered()
        assertEquals(0, reads)

        val snapshot = TweakRegistry.snapshot().single()

        assertEquals(1, reads)
        assertEquals(TweakType.ENUM, snapshot.descriptor.type)
        assertEquals(listOf("Automatic", "Manual"), snapshot.descriptor.options)
        assertEquals("Automatic", snapshot.descriptor.default)
        assertEquals("Automatic", snapshot.value)
        assertEquals(SpecializedPreviewMode.Automatic, registration.value)
        assertEquals(
            SnapOTweakValue.Selection("Automatic", listOf("Automatic", "Manual")),
            SnapOTweaks.activeTweakEntries().value.single().value.value,
        )
    }

    @Test
    fun `external enum selections update their owner and reject undeclared names`() {
        var owner = PreviewMode.Light
        var writes = 0
        val registration = TweakRegistration(
            testTweakBinding(
                "External enum",
                testTweakSource(
                    read = { owner },
                    onValueChange = {
                        writes++
                        owner = it
                    },
                ),
            ),
        )
        registration.onRemembered()

        val updated = TweakRegistry.update(mapOf("External enum" to "Dark")).single()

        assertEquals(PreviewMode.Dark, owner)
        assertEquals(PreviewMode.Dark, registration.value)
        assertEquals("Dark", updated.value)
        assertEquals(1, writes)
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.update(mapOf("External enum" to "Unknown"))
        }
        assertEquals(1, writes)
        assertEquals(PreviewMode.Dark, owner)
    }

    @Test
    fun `external enum owner changes and resets follow the current upstream selection`() {
        var upstream = PreviewMode.Light
        var override: PreviewMode? = null
        var resets = 0
        val registration = TweakRegistration(
            testTweakBinding(
                "External enum",
                testTweakSource(
                    read = { override ?: upstream },
                    onValueChange = { override = it },
                    onReset = {
                        resets++
                        override = null
                    },
                    modified = { override != null },
                ),
            ),
        )
        registration.onRemembered()
        val entry = SnapOTweaks.activeTweakEntries().value.single()
        assertEquals("Light", TweakRegistry.snapshot().single().descriptor.default)

        upstream = PreviewMode.Dark
        registration.notifyChanged()

        assertEquals(PreviewMode.Dark, registration.value)
        assertEquals("Dark", TweakRegistry.snapshot(cachedOnly = true).single().value)
        assertEquals("Dark", (entry.value.value as SnapOTweakValue.Selection).value)
        assertEquals(false, entry.modified.value)

        TweakRegistry.update(mapOf("External enum" to "Dark"))
        assertEquals(true, entry.modified.value)
        upstream = PreviewMode.System
        val reset = TweakRegistry.update(mapOf("External enum" to null)).single()

        assertEquals(1, resets)
        assertEquals(null, override)
        assertEquals(PreviewMode.System, registration.value)
        assertEquals("System", reset.value)
        assertEquals(false, reset.modified)
        assertEquals(false, entry.modified.value)
        assertEquals("Light", reset.descriptor.default)
    }

    @Test
    fun `shared external enum registrations decode through their selected owner`() {
        var firstOwner = PreviewMode.Light
        var secondOwner = PreviewMode.Dark
        var secondReads = 0
        val first = TweakRegistration(
            testTweakBinding(
                "Shared enum",
                testTweakSource(read = { firstOwner }, onValueChange = { firstOwner = it }),
            ),
        )
        val second = TweakRegistration(
            testTweakBinding(
                "Shared enum",
                testTweakSource(
                    read = {
                        secondReads++
                        secondOwner
                    },
                    onValueChange = { secondOwner = it },
                ),
            ),
        )
        first.onRemembered()
        second.onRemembered()

        assertEquals(PreviewMode.Light, second.value)
        TweakRegistry.update(mapOf("Shared enum" to "System"))
        assertEquals(PreviewMode.System, firstOwner)
        assertEquals(PreviewMode.System, second.value)
        assertEquals(0, secondReads)

        first.onForgotten()

        assertEquals(PreviewMode.Dark, second.value)
        assertEquals(1, secondReads)
        TweakRegistry.update(mapOf("Shared enum" to "Light"))
        assertEquals(PreviewMode.Light, secondOwner)
        assertEquals(PreviewMode.Light, second.value)
    }

    @Test
    fun `external enum registrations use replacement source values and callbacks`() {
        var firstOwner = PreviewMode.Light
        var secondOwner = PreviewMode.Dark
        val latest = mutableStateOf(
            testTweakSource(read = { firstOwner }, onValueChange = { firstOwner = it }),
        )
        val registration = TweakRegistration(ExternalTweakBinding("Replaced enum", latest))
        registration.onRemembered()
        assertEquals(PreviewMode.Light, registration.value)
        latest.value = testTweakSource(
            read = { secondOwner },
            onValueChange = { secondOwner = it },
            onReset = { secondOwner = PreviewMode.Dark },
        )
        registration.notifyChanged()

        assertEquals(PreviewMode.Dark, registration.value)
        TweakRegistry.update(mapOf("Replaced enum" to "System"))
        assertEquals(PreviewMode.Light, firstOwner)
        assertEquals(PreviewMode.System, secondOwner)
        assertEquals(PreviewMode.System, registration.value)
        TweakRegistry.update(mapOf("Replaced enum" to null))
        assertEquals(PreviewMode.Dark, secondOwner)
        assertEquals(PreviewMode.Dark, registration.value)
    }

    private enum class PreviewMode { System, Light, Dark }

    private enum class SpecializedPreviewMode {
        Automatic {
            override fun toString(): String = "Automatic preview"
        },
        Manual,
    }
}

package com.openai.snapo.tweaks

import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakRegistrationTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `remembering registers the existing composition value without changing it`() {
        val registration = registration(descriptor())

        assertEquals(16, registration.value)
        assertTrue(TweakRegistry.snapshot().isEmpty())

        registration.onRemembered()

        assertEquals(16, registration.value)
        assertEquals(16, TweakRegistry.snapshot().single().value)
    }

    @Test
    fun `forgetting removes the composition registration`() {
        val registration = registration(descriptor())
        registration.onRemembered()

        registration.onForgotten()

        assertNoActiveTweaks()
    }

    @Test
    fun `abandoning removes any already registered composition state`() {
        val registration = registration(descriptor())
        registration.onRemembered()

        registration.onAbandoned()

        assertNoActiveTweaks()
    }

    @Test
    fun `an unremembered registration never appears in active tweak lists`() {
        val registration = registration(descriptor())

        assertEquals(16, registration.value)
        assertNoActiveTweaks()
    }

    @Test
    fun `abandoning an unremembered registration never publishes a tweak`() {
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }
        val registration = registration(descriptor())

        registration.onAbandoned()

        assertEquals(16, registration.value)
        assertEquals(0, notifications)
        assertNoActiveTweaks()

        observer.close()
    }

    @Test
    fun `a forgotten registration retains its edit without publishing its cached value`() {
        val descriptor = descriptor()
        val registration = registration(descriptor)
        registration.onRemembered()
        TweakRegistry.update(mapOf(descriptor.name to 24))
        val observedNames = mutableListOf<List<String>>()
        val observer = TweakRegistry.observeChanges {
            observedNames += SnapOTweaks.activeTweaks().map { tweak -> tweak.name }
        }

        registration.onForgotten()

        assertEquals(24, registration.value)
        assertEquals(24, TweakRegistry.stateFor(descriptor).value)
        assertEquals(listOf(emptyList<String>()), observedNames)
        assertNoActiveTweaks()

        TweakRegistry.stateFor(descriptor)

        assertEquals(listOf(emptyList<String>()), observedNames)

        observer.close()
    }

    @Test
    fun `same-name composition registrations follow the same changed value`() {
        val descriptor = descriptor()
        val first = registration(descriptor)
        val second = registration(descriptor)
        first.onRemembered()
        TweakRegistry.update(mapOf(descriptor.name to 20))

        second.onRemembered()

        assertEquals(20, first.value)
        assertEquals(20, second.value)

        TweakRegistry.update(mapOf(descriptor.name to 24))

        assertEquals(24, first.value)
        assertEquals(24, second.value)

        first.onForgotten()
        second.onForgotten()
    }

    @Test
    fun `a new same-name registration returns the active value before being remembered`() {
        val descriptor = descriptor()
        val first = registration(descriptor)
        first.onRemembered()
        TweakRegistry.update(mapOf(descriptor.name to 20))

        val second = registration(descriptor)

        assertEquals(20, second.value)
        assertEquals(1, TweakRegistry.snapshot().size)

        second.onRemembered()

        assertEquals(20, first.value)
        assertEquals(20, second.value)

        first.onForgotten()
        second.onForgotten()
    }

    @Test
    fun `a new same-name registration rejects conflicting descriptors`() {
        val descriptor = descriptor()
        val first = registration(descriptor)
        first.onRemembered()
        val conflicting = registration(descriptor.copy(default = 24))

        assertThrows(IllegalArgumentException::class.java) {
            conflicting.onRemembered()
        }

        assertEquals(16, first.value)
        assertEquals(descriptor, TweakRegistry.snapshot().single().descriptor)

        first.onForgotten()
    }

    @Test
    fun `a changed descriptor replaces its forgotten composition registration`() {
        val firstDescriptor = descriptor()
        val replacementDescriptor = firstDescriptor.copy(default = 24)
        val first = registration(firstDescriptor)
        first.onRemembered()

        val replacement = registration(replacementDescriptor)
        assertEquals(24, replacement.value)

        first.onForgotten()
        replacement.onRemembered()

        assertEquals(24, replacement.value)
        assertEquals(replacementDescriptor, TweakRegistry.snapshot().single().descriptor)

        replacement.onForgotten()
    }

    @Test
    fun `registrations do not decode their values until observed`() {
        var decodes = 0
        val state = TweakRegistration(descriptor()) { value ->
            decodes += 1
            value as Int
        }

        assertEquals(0, decodes)
        assertEquals(16, state.value)
        assertEquals(1, decodes)
    }

    @Test
    fun `new same-name registrations do not observe existing state during composition`() {
        val descriptor = descriptor()
        val existing = registration(descriptor)
        existing.onRemembered()
        TweakRegistry.update(mapOf(descriptor.name to 20))
        var reads = 0

        val returning = Snapshot.observe(
            readObserver = { reads += 1 },
        ) {
            registration(descriptor)
        }

        assertEquals(0, reads)
        assertEquals(20, returning.value)

        existing.onForgotten()
    }

    @Test
    fun `color states preserve their exact default and restore it after reset`() {
        val default = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 0.3f,
            colorSpace = ColorSpaces.DisplayP3,
        )
        val encodedDefault = default.toTweakColor()
        val descriptor = colorDescriptor(encodedDefault)
        val state = TweakRegistration(descriptor) { value ->
            decodeTweakColor(value, default, encodedDefault)
        }
        state.onRemembered()

        assertEquals(default, state.value)

        TweakRegistry.update(mapOf(descriptor.name to "#112233"))
        assertEquals(Color(0xFF112233), state.value)

        TweakRegistry.update(mapOf(descriptor.name to encodedDefault))
        assertEquals(default, state.value)

        state.onForgotten()
    }

    @Test
    fun `unspecified color defaults remain unspecified until edited`() {
        val encodedDefault = Color.Unspecified.toTweakColor()
        val descriptor = colorDescriptor(encodedDefault)
        val state = TweakRegistration(descriptor) { value ->
            decodeTweakColor(value, Color.Unspecified, encodedDefault)
        }
        state.onRemembered()

        assertEquals("#00000000", encodedDefault)
        assertEquals(Color.Unspecified, state.value)

        TweakRegistry.update(mapOf(descriptor.name to "#112233"))
        assertEquals(Color(0xFF112233), state.value)

        TweakRegistry.update(mapOf(descriptor.name to encodedDefault))
        assertEquals(Color.Unspecified, state.value)

        state.onForgotten()
    }

    private fun registration(descriptor: TweakDescriptor) =
        TweakRegistration(descriptor) { value -> value as Int }

    private fun assertNoActiveTweaks() {
        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertTrue(TweakRegistry.activeEntries().value.isEmpty())
        assertTrue(SnapOTweaks.activeTweaks().isEmpty())
        assertTrue(SnapOTweaks.activeTweakEntries().value.isEmpty())
    }

    private fun colorDescriptor(default: String) = TweakDescriptor(
        name = "Lifecycle remembered color tweak",
        type = TweakType.COLOR,
        default = default,
    )

    private fun descriptor() = TweakDescriptor(
        name = "Lifecycle remembered tweak",
        type = TweakType.INT,
        default = 16,
    )
}

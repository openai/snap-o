package com.openai.snapo.tweaks

import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
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
    fun `enum tweak descriptors default to enum names in declaration order`() {
        val descriptor = enumTweakDescriptor(
            default = PreviewMode.Dark,
            name = "Appearance/Preview mode",
        )

        assertEquals(TweakType.ENUM, descriptor.type)
        assertEquals("Dark", descriptor.default)
        assertEquals(listOf("System", "Light", "Dark"), descriptor.options)
    }

    @Test
    fun `enum registrations decode updated constant names into their original type`() {
        val descriptor = enumTweakDescriptor(
            default = PreviewMode.Light,
            name = "Appearance/Preview mode",
        )
        val registration = TweakRegistration(descriptor) { storedValue ->
            PreviewMode.valueOf(storedValue as String)
        }

        assertEquals("Light", descriptor.default)
        assertEquals(listOf("System", "Light", "Dark"), descriptor.options)
        assertEquals(PreviewMode.Light, registration.value)

        registration.onRemembered()
        TweakRegistry.update(mapOf(descriptor.name to "Dark"))

        assertEquals(PreviewMode.Dark, registration.value)
        registration.onForgotten()
    }

    @Test
    fun `enum tweaks discover every option when the default has a constant specific body`() {
        val descriptor = enumTweakDescriptor(
            default = SpecializedPreviewMode.Automatic,
            name = "Appearance/Specialized preview mode",
        )

        assertEquals("Automatic", descriptor.default)
        assertEquals(listOf("Automatic", "Manual"), descriptor.options)
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
        val descriptor = colorDescriptor(default)
        val state = TweakRegistration(descriptor) { value ->
            (value as TweakColorValue).color
        }
        state.onRemembered()

        assertEquals(default, state.value)
        assertEquals(
            SnapOTweakValue.ColorValue(default),
            SnapOTweaks.activeTweakEntries().value.single().defaultValue,
        )
        assertEquals(
            SnapOTweakValue.ColorValue(default),
            SnapOTweaks.activeTweakEntries().value.single().value.value,
        )

        TweakRegistry.update(mapOf(descriptor.name to "#112233"))
        assertEquals(Color(0xFF112233), state.value)

        TweakRegistry.update(mapOf(descriptor.name to encodedDefault))
        assertEquals(default, state.value)

        state.onForgotten()
    }

    @Test
    fun `unspecified color defaults remain unspecified until edited`() {
        val encodedDefault = Color.Unspecified.toTweakColor()
        val descriptor = colorDescriptor(Color.Unspecified)
        val state = TweakRegistration(descriptor) { value ->
            (value as TweakColorValue).color
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

    @Test
    fun `same exact color defaults share retained state`() {
        val default = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 0.3f,
            colorSpace = ColorSpaces.DisplayP3,
        )
        val firstDescriptor = colorDescriptor(
            default = default,
            name = "Lifecycle shared exact color",
        )
        val secondDescriptor = colorDescriptor(
            default = default,
            name = firstDescriptor.name,
        )

        val first = TweakRegistry.register(firstDescriptor)
        val second = TweakRegistry.register(secondDescriptor)

        assertSame(first, second)
        assertEquals(default, (first.value as TweakColorValue).color)

        TweakRegistry.unregister(firstDescriptor.name)
        TweakRegistry.unregister(firstDescriptor.name)
    }

    @Test
    fun `unspecified and transparent defaults retain independent histories`() {
        assertIndependentColorHistories(
            firstDefault = Color.Unspecified,
            secondDefault = Color.Transparent,
            name = "Lifecycle unspecified and transparent colors",
        )
    }

    @Test
    fun `color-space collisions retain independent histories`() {
        val displayP3 = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 1f,
            colorSpace = ColorSpaces.DisplayP3,
        )
        val projectedSrgb = displayP3.toTweakColor().toTweakColor()

        assertIndependentColorHistories(
            firstDefault = displayP3,
            secondDefault = projectedSrgb,
            name = "Lifecycle color-space collisions",
        )
    }

    @Test
    fun `quantized alpha collisions retain independent histories`() {
        val first = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 0.5f,
            colorSpace = ColorSpaces.DisplayP3,
        )
        val second = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 0.5015f,
            colorSpace = ColorSpaces.DisplayP3,
        )

        assertIndependentColorHistories(
            firstDefault = first,
            secondDefault = second,
            name = "Lifecycle quantized alpha collisions",
        )
    }

    @Test
    fun `unsupported packed colors fail with a clear error`() {
        val unsupported = Color(value = ULong.MAX_VALUE)

        val error = assertThrows(IllegalArgumentException::class.java) {
            unsupported.toTweakColorValue()
        }

        assertTrue(error.message.orEmpty().contains("convertible to sRGB"))
    }

    private fun registration(descriptor: TweakDescriptor) =
        TweakRegistration(descriptor) { value -> value as Int }

    private fun assertNoActiveTweaks() {
        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertTrue(TweakRegistry.activeEntries().value.isEmpty())
        assertTrue(SnapOTweaks.activeTweaks().isEmpty())
        assertTrue(SnapOTweaks.activeTweakEntries().value.isEmpty())
    }

    private fun assertIndependentColorHistories(
        firstDefault: Color,
        secondDefault: Color,
        name: String,
    ) {
        val firstDescriptor = colorDescriptor(firstDefault, name)
        val secondDescriptor = colorDescriptor(secondDefault, name)

        assertNotEquals(firstDefault, secondDefault)
        assertEquals(
            (firstDescriptor.default as TweakColorValue).wireValue,
            (secondDescriptor.default as TweakColorValue).wireValue,
        )
        assertNotEquals(firstDescriptor, secondDescriptor)

        val firstState = TweakRegistry.register(firstDescriptor)
        TweakRegistry.update(mapOf(name to "#112233"))
        TweakRegistry.unregister(name)

        val secondState = TweakRegistry.register(secondDescriptor)
        assertNotSame(firstState, secondState)
        assertEquals(secondDefault, (secondState.value as TweakColorValue).color)
        TweakRegistry.update(mapOf(name to "#445566"))
        TweakRegistry.unregister(name)

        val restoredFirst = TweakRegistry.register(firstDescriptor)
        assertSame(firstState, restoredFirst)
        assertEquals(Color(0xFF112233), (restoredFirst.value as TweakColorValue).color)
        TweakRegistry.unregister(name)

        val restoredSecond = TweakRegistry.register(secondDescriptor)
        assertSame(secondState, restoredSecond)
        assertEquals(Color(0xFF445566), (restoredSecond.value as TweakColorValue).color)
        TweakRegistry.unregister(name)
    }

    private fun colorDescriptor(
        default: Color,
        name: String = "Lifecycle remembered color tweak",
    ) = TweakDescriptor(
        name = name,
        type = TweakType.COLOR,
        default = default.toTweakColorValue(),
    )

    private fun descriptor() = TweakDescriptor(
        name = "Lifecycle remembered tweak",
        type = TweakType.INT,
        default = 16,
    )

    private enum class PreviewMode {
        System,
        Light,
        Dark,
    }

    private enum class SpecializedPreviewMode {
        Automatic {
            override fun toString(): String = "Automatic"
        },
        Manual,
    }
}

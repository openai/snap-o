package com.openai.snapo.tweaks

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SnapOTweaksTest {

    @Before
    fun allowTweaksRuntime() {
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)
    }

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
    }

    @Test
    fun `active tweaks preserve registration order and numeric constraints`() {
        TweakRegistry.register(
            TweakDescriptor(
                name = "Typography/Font size",
                type = TweakType.INT,
                default = 16,
                min = 12,
                max = 32,
                step = 2,
            ),
        )
        TweakRegistry.register(
            TweakDescriptor(
                name = "Motion/Damping",
                type = TweakType.FLOAT,
                default = 0.5f,
                min = 0.1f,
                max = 1f,
                step = 0.1f,
            ),
        )

        assertEquals(
            listOf(
                SnapOTweak(
                    name = "Typography/Font size",
                    value = SnapOTweakValue.Integer(16, 12, 32, 2),
                    defaultValue = SnapOTweakValue.Integer(16, 12, 32, 2),
                ),
                SnapOTweak(
                    name = "Motion/Damping",
                    value = SnapOTweakValue.Floating(0.5f, 0.1f, 1f, 0.1f),
                    defaultValue = SnapOTweakValue.Floating(0.5f, 0.1f, 1f, 0.1f),
                ),
            ),
            SnapOTweaks.activeTweaks(),
        )
    }

    @Test
    fun `overlay updates use the shared tweak registry`() {
        val descriptor = TweakDescriptor(
            name = "Typography/Font size",
            type = TweakType.INT,
            default = 16,
            min = 12,
            max = 32,
        )
        val state = TweakRegistry.register(descriptor)

        SnapOTweaks.update(descriptor.name, SnapOTweakValue.Integer(20, 12, 32))

        assertEquals(20, state.value)
        assertEquals(SnapOTweakValue.Integer(20, 12, 32), SnapOTweaks.activeTweaks().single().value)
    }

    @Test
    fun `enum overlay values expose and update enum constant names`() {
        val options = listOf("System", "Light", "Dark")
        val descriptor = TweakDescriptor(
            name = "Appearance/Theme",
            type = TweakType.ENUM,
            default = "System",
            options = options,
        )
        val state = TweakRegistry.register(descriptor)
        val entry = SnapOTweaks.activeTweakEntries().value.single()

        assertEquals(SnapOTweakValue.Selection("System", options), entry.value.value)
        assertEquals(SnapOTweakValue.Selection("System", options), entry.defaultValue)

        SnapOTweaks.update(descriptor.name, SnapOTweakValue.Selection("Dark", options))

        assertEquals("Dark", state.value)
        assertEquals(SnapOTweakValue.Selection("Dark", options), entry.value.value)

        SnapOTweaks.update(descriptor.name, entry.defaultValue)

        assertEquals("System", state.value)
        assertEquals(SnapOTweakValue.Selection("System", options), entry.value.value)
    }

    @Test
    fun `overlay updates remain available as adjusted history after leaving composition`() {
        val descriptor = TweakDescriptor(
            name = "Typography/Historical font size",
            type = TweakType.INT,
            default = 16,
        )
        TweakRegistry.register(descriptor)

        SnapOTweaks.update(descriptor.name, SnapOTweakValue.Integer(20))
        TweakRegistry.unregister(descriptor.name)

        assertTrue(SnapOTweaks.activeTweaks().isEmpty())
        assertEquals(20, TweakRegistry.snapshot(includeAdjusted = true).single().value)
    }

    @Test
    fun `release updates without an override ignore unavailable tweaks`() {
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)

        SnapOTweaks.update("Typography/Unavailable font size", SnapOTweakValue.Integer(20))

        assertTrue(SnapOTweaks.activeTweaks().isEmpty())
    }

    @Test
    fun `release updates without an override do not change registered tweaks`() {
        val descriptor = TweakDescriptor(
            name = "Typography/Protected font size",
            type = TweakType.INT,
            default = 16,
        )
        val state = TweakRegistry.register(descriptor)
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)

        SnapOTweaks.update(descriptor.name, SnapOTweakValue.Integer(20))

        assertEquals(16, state.value)
    }

    @Test
    fun `release invocations without an override do not run registered actions`() {
        var invocations = 0
        val registration = TweakRegistry.registerAction("Playback/Restart") { invocations += 1 }
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)

        SnapOTweaks.invokeAction("Playback/Restart")

        assertEquals(0, invocations)
        registration.close()
    }

    @Test
    fun `observable entries keep their identity while individual values update`() {
        val descriptor = TweakDescriptor(
            name = "Typography/Observable font size",
            type = TweakType.INT,
            default = 16,
            min = 12,
            max = 32,
        )
        val entries = SnapOTweaks.activeTweakEntries()
        TweakRegistry.register(descriptor)
        val initialEntries = entries.value
        val entry = initialEntries.single()
        val value = entry.value

        assertEquals(SnapOTweakValue.Integer(16, 12, 32), value.value)

        SnapOTweaks.update(descriptor.name, SnapOTweakValue.Integer(20, 12, 32))

        assertSame(initialEntries, entries.value)
        assertSame(entry, entries.value.single())
        assertSame(value, entry.value)
        assertEquals(SnapOTweakValue.Integer(20, 12, 32), value.value)
    }

    @Test
    fun `observable entries update their membership in registration order`() {
        val entries = SnapOTweaks.activeTweakEntries()
        val first = TweakDescriptor(
            name = "Typography/First",
            type = TweakType.INT,
            default = 16,
        )
        val second = TweakDescriptor(
            name = "Motion/Second",
            type = TweakType.BOOLEAN,
            default = true,
        )

        TweakRegistry.register(first)
        val firstEntry = entries.value.single()
        TweakRegistry.register(second)

        assertEquals(listOf(first.name, second.name), entries.value.map { it.name })
        assertSame(firstEntry, entries.value.first())

        TweakRegistry.unregister(first.name)

        assertEquals(listOf(second.name), entries.value.map { it.name })
    }

    @Test
    fun `floating point overlay updates respect decimal steps`() {
        val descriptor = TweakDescriptor(
            name = "Motion/Spring damping",
            type = TweakType.FLOAT,
            default = 0.7f,
            min = 0.1f,
            max = 1f,
            step = 0.05f,
        )
        val state = TweakRegistry.register(descriptor)

        SnapOTweaks.update(
            descriptor.name,
            SnapOTweakValue.Floating(0.75f, 0.1f, 1f, 0.05f),
        )

        assertEquals(0.75f, state.value)
    }

    @Test
    fun `colors round trip between overlay and registry`() {
        val descriptor = TweakDescriptor(
            name = "Colors/Accent",
            type = TweakType.COLOR,
            default = "#5468FF".toTweakColorValue(),
        )
        val state = TweakRegistry.register(descriptor)

        assertEquals(
            SnapOTweakValue.ColorValue(Color(0xFF5468FF)),
            SnapOTweaks.activeTweaks().single().value,
        )

        SnapOTweaks.update(
            descriptor.name,
            SnapOTweakValue.ColorValue(Color(0xFF112233)),
        )

        assertEquals("#112233", (state.value as TweakColorValue).wireValue)
    }

    @Test
    fun `color entries preserve exact defaults and overlay resets`() {
        val default = Color(
            red = 0.25f,
            green = 0.5f,
            blue = 0.75f,
            alpha = 0.3f,
            colorSpace = ColorSpaces.DisplayP3,
        )
        val descriptor = TweakDescriptor(
            name = "Colors/Exact accent",
            type = TweakType.COLOR,
            default = default.toTweakColorValue(),
        )
        val state = TweakRegistry.register(descriptor)
        val entry = SnapOTweaks.activeTweakEntries().value.single()
        val projectedSrgb = default.toTweakColor().toTweakColor()
        val edited = Color(
            red = 0.9f,
            green = 0.1f,
            blue = 0.2f,
            alpha = 0.7f,
            colorSpace = ColorSpaces.DisplayP3,
        )

        assertEquals(SnapOTweakValue.ColorValue(default), entry.value.value)
        assertEquals(SnapOTweakValue.ColorValue(default), entry.defaultValue)

        SnapOTweaks.update(
            descriptor.name,
            SnapOTweakValue.ColorValue(projectedSrgb),
        )

        assertNotEquals(default, projectedSrgb)
        assertEquals(projectedSrgb, (state.value as TweakColorValue).color)
        assertEquals(SnapOTweakValue.ColorValue(projectedSrgb), entry.value.value)

        SnapOTweaks.update(
            descriptor.name,
            SnapOTweakValue.ColorValue(edited),
        )

        assertEquals(edited, (state.value as TweakColorValue).color)
        assertEquals(SnapOTweakValue.ColorValue(edited), entry.value.value)

        SnapOTweaks.update(descriptor.name, entry.defaultValue)

        assertEquals(default, (state.value as TweakColorValue).color)
        assertEquals(SnapOTweakValue.ColorValue(default), entry.value.value)
    }

    @Test
    fun `observers receive registration updates and removal`() {
        val snapshots = mutableListOf<List<SnapOTweak>>()
        val observer = TweakRegistry.observeChanges {
            snapshots += SnapOTweaks.activeTweaks()
        }
        val descriptor = TweakDescriptor(
            name = "Motion/Enabled",
            type = TweakType.BOOLEAN,
            default = true,
        )

        TweakRegistry.register(descriptor)
        SnapOTweaks.update(descriptor.name, SnapOTweakValue.Toggle(false))
        TweakRegistry.unregister(descriptor.name)
        observer.close()

        assertEquals(3, snapshots.size)
        assertEquals(SnapOTweakValue.Toggle(true), snapshots[0].single().value)
        assertEquals(SnapOTweakValue.Toggle(false), snapshots[1].single().value)
        assertTrue(snapshots[2].isEmpty())
    }

    @Test
    fun `closed observers stop receiving changes`() {
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        observer.close()
        TweakRegistry.register(
            TweakDescriptor(
                name = "Typography/Preview text",
                type = TweakType.STRING,
                default = "Hello",
            ),
        )

        assertEquals(0, notifications)
    }
}

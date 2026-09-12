package com.openai.snapo.tweaks

import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.graphics.Color
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class TweakCoreInteropTest {
    @Before
    fun allowTweaks() {
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)
    }

    @After
    fun clearTweaks() {
        TweakRegistry.clear()
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
    }

    @Test
    fun `Compose and core share values while retaining independent ownership`() {
        TweakScope().use { scope ->
            val flow = scope.tweak(16, "Shared size")
            val registration = TweakRegistration(TweakDescriptor("Shared size", TweakType.INT, 16)) { it as Int }
            registration.onRemembered()
            SnapOTweaks.update("Shared size", SnapOTweakValue.Integer(24))
            assertEquals(24, flow.value)
            assertEquals(24, registration.value)
            registration.onForgotten()
            assertEquals(1, TweakRegistry.snapshot().size)
            SnapOTweaks.reset("Shared size")
            assertEquals(16, flow.value)
        }
        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `core updates invalidate Compose snapshot observations`() = runBlocking {
        TweakScope().use { scope ->
            scope.tweak(16, "Shared size")
            val registration = TweakRegistration(TweakDescriptor("Shared size", TweakType.INT, 16)) { it as Int }
            registration.onRemembered()
            val values = mutableListOf<Int>()
            val collection = launch(start = CoroutineStart.UNDISPATCHED) {
                snapshotFlow { registration.value }.take(2).toList(values)
            }
            TweakRegistry.update(mapOf("Shared size" to 24))
            Snapshot.sendApplyNotifications()
            withTimeout(1_000) { collection.join() }
            assertEquals(listOf(16, 24), values)
            registration.onForgotten()
        }
    }

    @Test
    fun `Compose sRGB colors and Android ARGB colors share a declaration`() {
        val argb = 0x80112233.toInt()
        TweakScope().use { scope ->
            val flow = scope.tweakColor(argb, "Shared color")
            val registration = TweakRegistration(
                TweakDescriptor("Shared color", TweakType.COLOR, Color(argb).toTweakColorValue()),
            ) { (it as TweakColorValue).color }
            registration.onRemembered()
            SnapOTweaks.update("Shared color", SnapOTweakValue.ColorValue(Color.Red))
            assertEquals(0xFFFF0000.toInt(), flow.value)
            assertEquals(Color.Red, registration.value)
            SnapOTweaks.reset("Shared color")
            assertEquals(argb, flow.value)
            assertEquals(Color(argb), registration.value)
            registration.onForgotten()
        }
    }
}

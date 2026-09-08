package com.openai.snapo.tweaks

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TweakScopeTest {
    @Test
    fun `defaults remain available without exposing mutable state`() {
        TweakScope().use { scope ->
            val values = listOf(
                scope.tweak(3, "Count"),
                scope.tweak(0.5f, "Scale"),
                scope.tweak(false, "Enabled"),
                scope.tweak("Hello", "Text"),
                scope.tweak(Mode.FIRST, "Mode"),
                scope.tweakColor(0xFF112233.toInt(), "Color"),
            )
            assertEquals(listOf(3, 0.5f, false, "Hello", Mode.FIRST, 0xFF112233.toInt()), values.map { it.value })
            values.forEach { assertFalse(it is MutableStateFlow<*>) }
            scope.action("Replay") { error("No-op actions must never run") }
        }
    }

    @Test
    fun `curve defaults retain their type without an inspector`() {
        val curve = BezierCurve(0.2f, -0.5f, 0.8f, 1.5f)
        val scope = TweakScope()
        val state = scope.tweak(curve, "Curve")
        assertEquals(curve, state.value)
        scope.close()
        assertEquals(curve, state.value)
        assertThrows(IllegalStateException::class.java) { scope.tweak(curve, "Closed") }
    }

    @Test
    fun `closing is idempotent and rejects new declarations`() {
        val scope = TweakScope()
        val value = scope.tweak(3, "Count")
        scope.close()
        scope.close()
        assertEquals(3, value.value)
        assertThrows(IllegalStateException::class.java) { scope.tweak(4, "Count") }
    }

    @Test
    fun `sources remain app owned and stop observing at close`() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
        var current = 3
        val source = object : TweakSource<Int> {
            override var value: Int
                get() = current
                set(value) { error("Must not write") }
            override val isModified: Boolean get() = error("Must not inspect status")
            override fun reset() = error("Must not reset")
            override fun observe(): Flow<Unit> = changes
        }
        try {
            val scope = TweakScope()
            val value = scope.tweak(source, "Setting")
            assertEquals(3, value.value)
            assertEquals(1, changes.subscriptionCount.value)
            current = 4
            changes.tryEmit(Unit)
            assertEquals(4, value.value)
            scope.close()
            assertEquals(0, changes.subscriptionCount.value)
        } finally {
            Dispatchers.resetMain()
        }
    }

    private enum class Mode { FIRST }
}

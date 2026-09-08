package com.openai.snapo.tweaks.internal

import com.openai.snapo.tweaks.BezierCurve
import com.openai.snapo.tweaks.TweakScope
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class BezierTweakTest {
    private val linear = BezierCurve(0f, 0f, 1f, 1f)

    @After
    fun clear() {
        TweakRegistry.clear()
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
    }

    private fun BezierCurve.coordinates(): Map<String, Float> =
        mapOf("x1" to x1, "y1" to y1, "x2" to x2, "y2" to y2)

    @Test
    fun `coordinate objects preserve normalized values`() {
        val curve = BezierCurve(0.2f, 0.1f, 0.8f, 0.9f)
        assertEquals(curve, parseBezierCurve(curve.coordinates()))
    }

    @Test
    fun `malformed nonfinite and out of range coordinates are rejected`() {
        listOf(
            linear.coordinates() + ("x1" to -0.1f),
            linear.coordinates() + ("x2" to 1.1f),
            linear.coordinates() + ("y1" to -0.1f),
            linear.coordinates() + ("y2" to 1.1f),
            linear.coordinates() + ("y1" to Float.NaN),
            linear.coordinates() + ("y2" to 1e99),
            linear.coordinates() + ("x1" to true),
            linear.coordinates() + ("y1" to "0.5"),
            linear.coordinates() - "y1",
            linear.coordinates() + ("extra" to 0f),
        ).forEach { assertNull(it.toString(), parseBezierCurve(it)) }
        assertThrows(IllegalArgumentException::class.java) { BezierCurve(0f, Float.NaN, 1f, 1f) }
        assertThrows(IllegalArgumentException::class.java) { BezierCurve(0f, -0.1f, 1f, 1f) }
        assertThrows(IllegalArgumentException::class.java) { BezierCurve(0f, 0f, 1f, 1.1f) }
    }

    @Test
    fun `a whole curve updates resets and restores across owners`() {
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)
        val edited = BezierCurve(0.25f, 0.1f, 0.75f, 0.9f)
        TweakScope().use { scope ->
            val state = scope.tweak(linear, "Motion/Curve")
            TweakRegistry.update(mapOf("Motion/Curve" to edited.coordinates()))
            assertEquals(edited, state.value)
            assertTrue(TweakRegistry.snapshot().single().modified)
            assertThrows(TweakUpdateException::class.java) {
                TweakRegistry.update(mapOf("Motion/Curve" to (linear.coordinates() + ("x1" to 2f))))
            }
            assertEquals(edited, state.value)
        }
        TweakScope().use { scope ->
            val state = scope.tweak(linear, "Motion/Curve")
            assertEquals(edited, state.value)
            TweakRegistry.update(mapOf("Motion/Curve" to null))
            assertEquals(linear, state.value)
        }
    }

    @Test
    fun `Y bounds constrain defaults and updates`() {
        val default = BezierCurve(0f, 0.2f, 1f, 0.8f)
        val descriptor = TweakDescriptor("Curve", TweakType.BEZIER, default, yMin = 0.2f, yMax = 0.8f)
        val state = TweakRegistry.register(descriptor)
        assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.update(mapOf("Curve" to linear.coordinates()))
        }
        assertEquals(default, state.value)
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(descriptor.copy(name = "Invalid", yMin = Float.NaN))
        }
        assertThrows(IllegalArgumentException::class.java) {
            TweakRegistry.register(descriptor.copy(name = "Overshoot", yMin = -1f, yMax = 2f))
        }
        assertThrows(TweakUpdateException::class.java) {
            TweakRegistry.register(descriptor.copy(name = "Outside", default = linear))
        }
    }
}

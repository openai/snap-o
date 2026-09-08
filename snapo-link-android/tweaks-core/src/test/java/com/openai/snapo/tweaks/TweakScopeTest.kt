package com.openai.snapo.tweaks

import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TweakScopeTest {
    private val scopes = mutableListOf<TweakScope>()

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)
    }

    @After
    fun tearDown() {
        scopes.forEach { it.close() }
        TweakRegistry.clear()
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
        Dispatchers.resetMain()
    }

    @Test
    fun `values register and update without collectors`() {
        val scope = scope()
        val width = scope.tweak(16f, "Width", 0f..48f)
        assertEquals(16f, width.value)
        assertEquals(listOf("Width"), TweakRegistry.snapshot().map { it.descriptor.name })

        TweakRegistry.update(mapOf("Width" to 24))
        assertEquals(24f, width.value)
        assertFalse(width is MutableStateFlow<*>)

        TweakRegistry.update(mapOf("Width" to null))
        assertEquals(16f, width.value)
    }

    @Test
    fun `all supported value types retain their Kotlin type`() {
        val scope = scope()
        val values: List<StateFlow<*>> = listOf(
            scope.tweak(4, "Count", 0..10, 2),
            scope.tweak(false, "Enabled"),
            scope.tweak("Hello", "Text"),
            scope.tweak(Mode.FIRST, "Mode"),
            scope.tweakColor(0xFF112233.toInt(), "Color"),
        )
        TweakRegistry.update(
            mapOf("Count" to 6, "Enabled" to true, "Text" to "World", "Mode" to "SECOND", "Color" to "#44556680"),
        )
        assertEquals(listOf(6, true, "World", Mode.SECOND, 0x80445566.toInt()), values.map { it.value })
        assertThrows(IllegalArgumentException::class.java) { scope.tweak(7, "Invalid", 0..5) }
        assertEquals(5, TweakRegistry.snapshot().size)
    }

    @Test
    fun `owners share edits and closing one does not unregister another`() {
        val first = scope()
        val second = scope()
        val firstValue = first.tweak(4, "Shared")
        val secondValue = second.tweak(4, "Shared")
        TweakRegistry.update(mapOf("Shared" to 6))
        assertEquals(6, firstValue.value)
        assertEquals(6, secondValue.value)
        first.close()
        first.close()
        TweakRegistry.update(mapOf("Shared" to 8))
        assertEquals(6, firstValue.value)
        assertEquals(8, secondValue.value)
        second.close()
        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertEquals(8, scope().tweak(4, "Shared").value)
        assertThrows(IllegalStateException::class.java) { first.tweak(1, "Closed") }
    }

    @Test
    fun `conflicts do not steal an existing registration`() {
        val first = scope().tweak(4, "Shared")
        val conflicting = scope()
        assertThrows(IllegalArgumentException::class.java) { conflicting.tweak(8, "Shared") }
        conflicting.close()
        TweakRegistry.update(mapOf("Shared" to 6))
        assertEquals(6, first.value)
    }

    @Test
    fun `actions run only when invoked and are released on close`() {
        val scope = scope()
        var invocations = 0
        scope.action("Replay") { invocations++ }
        assertEquals(0, invocations)
        TweakRegistry.invokeAction("Replay")
        assertEquals(1, invocations)
        scope.close()
        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `source changes and resets remain application owned`() {
        val source = Source(3)
        val scope = scope()
        val value = scope.tweak(source, "Setting")
        assertEquals(1, source.changes.subscriptionCount.value)
        TweakRegistry.update(mapOf("Setting" to 30))
        assertEquals(10, value.value)
        assertTrue(TweakRegistry.snapshot().single().modified)
        source.upstream = 7
        TweakRegistry.update(mapOf("Setting" to null))
        assertEquals(7, value.value)
        assertFalse(TweakRegistry.snapshot().single().modified)
        source.value = 9
        source.changes.tryEmit(Unit)
        assertEquals(9, value.value)
        scope.close()
        assertEquals(0, source.changes.subscriptionCount.value)
    }

    @Test
    fun `source observation transfers to the next active owner`() {
        val first = scope()
        val second = scope()
        val firstSource = Source(3)
        val secondSource = Source(7)
        first.tweak(firstSource, "Setting")
        val value = second.tweak(secondSource, "Setting")
        assertEquals(3, value.value)
        assertEquals(1, firstSource.changes.subscriptionCount.value)
        assertEquals(0, secondSource.changes.subscriptionCount.value)
        assertEquals(0, secondSource.reads)
        first.close()
        assertEquals(7, value.value)
        assertEquals(0, firstSource.changes.subscriptionCount.value)
        assertEquals(1, secondSource.changes.subscriptionCount.value)
    }

    @Test
    fun `disabled runtime exposes defaults and observes sources without registering`() {
        TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
        val scope = scope()
        assertEquals(3, scope.tweak(3, "Number").value)
        scope.action("Action") { error("Must not run") }
        val source = Source(4)
        val value = scope.tweak(source, "Source")
        source.value = 5
        source.changes.tryEmit(Unit)
        assertEquals(5, value.value)
        assertTrue(TweakRegistry.snapshot().isEmpty())
        scope.close()
        assertEquals(0, source.changes.subscriptionCount.value)
    }

    @Test
    fun `ordinary values can be registered read and closed on a worker`() {
        var result = 0
        var failure: Throwable? = null
        val thread = Thread {
            try {
                TweakScope().use { scope ->
                    val value = scope.tweak(1, "Worker")
                    TweakRegistry.update(mapOf("Worker" to 2))
                    result = value.value
                }
            } catch (error: Throwable) {
                failure = error
            }
        }
        thread.start()
        thread.join(5_000)
        assertFalse(thread.isAlive)
        failure?.let { throw AssertionError(it) }
        assertEquals(2, result)
        assertTrue(TweakRegistry.snapshot().isEmpty())
    }

    @Test
    fun `failed final source reads still release all registrations`() {
        val scope = scope()
        val changes = MutableSharedFlow<Unit>()
        var failReads = false
        var current = 3
        val source = object : TweakSource<Int> {
            override var value: Int
                get() = if (failReads) error("Owner disposed") else current
                set(value) { current = value }
            override val isModified: Boolean get() = true
            override fun reset() = Unit
            override fun observe(): Flow<Unit> = changes
        }
        scope.tweak(1, "Ordinary")
        scope.tweak(source, "Setting")
        TweakRegistry.update(mapOf("Setting" to 4))
        failReads = true
        assertThrows(IllegalStateException::class.java) { scope.close() }
        assertTrue(TweakRegistry.snapshot().isEmpty())
        assertEquals(0, changes.subscriptionCount.value)
        scope.close()
    }

    private fun scope() = TweakScope().also { scopes.add(it) }
    private enum class Mode { FIRST, SECOND }

    private class Source(var upstream: Int) : TweakSource<Int> {
        val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
        private var override: Int? = null
        var reads = 0
        override var value: Int
            get() = (override ?: upstream).also { reads++ }
            set(value) { override = value.coerceIn(0, 10) }
        override val isModified: Boolean get() = override != null
        override fun reset() { override = null }
        override fun observe(): Flow<Unit> = changes
    }
}

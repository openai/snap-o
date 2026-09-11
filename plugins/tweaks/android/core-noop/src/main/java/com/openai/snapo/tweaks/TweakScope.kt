@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.tweaks

import androidx.annotation.MainThread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.Closeable

/** Returns defaults without registering tweaks or starting a tool. */
@Suppress("TooManyFunctions")
class TweakScope : Closeable {
    private val observationJob = SupervisorJob()
    private val observationScope by lazy {
        CoroutineScope(observationJob + Dispatchers.Main.immediate)
    }

    @Volatile
    private var closed = false

    fun tweak(
        default: Float,
        name: String,
        range: ClosedFloatingPointRange<Float>? = null,
        step: Float? = null,
    ): StateFlow<Float> = state(default)

    fun tweak(
        default: Int,
        name: String,
        range: IntRange? = null,
        step: Int? = null,
    ): StateFlow<Int> = state(default)

    fun tweak(
        default: BezierCurve,
        name: String,
    ): StateFlow<BezierCurve> = state(default)

    fun tweak(default: Boolean, name: String): StateFlow<Boolean> = state(default)
    fun tweak(default: String, name: String): StateFlow<String> = state(default)
    fun <E : Enum<E>> tweak(default: E, name: String): StateFlow<E> = state(default)
    fun tweakColor(default: Int, name: String): StateFlow<Int> = state(default)

    /** Observes application changes without modifying the source or exposing it to a tool. */
    @MainThread
    fun <T : Any> tweak(source: TweakSource<T>, name: String): StateFlow<T> {
        checkOpen()
        val value = MutableStateFlow(source.value)
        observationScope.launch { source.observe().collect { value.value = source.value } }
        return value.asStateFlow()
    }

    @MainThread
    fun tweakColor(source: TweakSource<Int>, name: String): StateFlow<Int> = tweak(source, name)

    fun action(name: String, onInvoke: () -> Unit) { checkOpen() }

    override fun close() {
        closed = true
        observationJob.cancel()
    }

    private fun checkOpen() = check(!closed) { "TweakScope is closed." }

    private fun <T> state(default: T): StateFlow<T> {
        checkOpen()
        return MutableStateFlow(default).asStateFlow()
    }
}

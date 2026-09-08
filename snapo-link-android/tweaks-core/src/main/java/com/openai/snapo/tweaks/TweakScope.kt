package com.openai.snapo.tweaks

import androidx.annotation.MainThread
import com.openai.snapo.tweaks.internal.ExternalTweakBacking
import com.openai.snapo.tweaks.internal.SelectedTweakState
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakState
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.io.Closeable

/**
 * Owns tweaks independently of a UI framework. Close this scope when its owner is disposed.
 *
 * Values are registered immediately, even without collectors. Returned flows are read-only and
 * retain their last value after close; callers own their collecting coroutines. Matching live
 * declarations share a value. A conflicting declaration is rejected.
 *
 * Ordinary declarations and reads can be used from any thread. Scopes containing app-owned
 * sources must register those sources and close on the main thread, where source methods run.
 */
@Suppress("TooManyFunctions")
class TweakScope : Closeable {
    private val lock = Any()
    private val resources = ArrayList<Closeable>()
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
    ): StateFlow<Float> = register(
        TweakDescriptor(name, TweakType.FLOAT, default, range?.start, range?.endInclusive, step),
    ) { it as Float }

    fun tweak(
        default: Int,
        name: String,
        range: IntRange? = null,
        step: Int? = null,
    ): StateFlow<Int> = register(
        TweakDescriptor(name, TweakType.INT, default, range?.first, range?.last, step),
    ) { it as Int }

    fun tweak(default: Boolean, name: String): StateFlow<Boolean> = register(
        TweakDescriptor(name, TweakType.BOOLEAN, default),
    ) { it as Boolean }

    fun tweak(default: String, name: String): StateFlow<String> = register(
        TweakDescriptor(name, TweakType.STRING, default),
    ) { it as String }

    fun <E : Enum<E>> tweak(default: E, name: String): StateFlow<E> = register(
        TweakDescriptor(
            name,
            TweakType.ENUM,
            default.name,
            options = requireNotNull(default.declaringJavaClass.enumConstants).map { it.name },
        ),
    ) { java.lang.Enum.valueOf(default.declaringJavaClass, it as String) }

    /** Exposes an Android ARGB color, distinct from an ordinary integer tweak. */
    fun tweakColor(default: Int, name: String): StateFlow<Int> = register(
        TweakDescriptor(name, TweakType.COLOR, default.toTweakColorValue()),
    ) { (it as TweakColorValue).toArgb() }

    /** Exposes a Boolean, Int, Float, or String using the source's own reset and override status. */
    @MainThread
    fun <T : Any> tweak(source: TweakSource<T>, name: String): StateFlow<T> =
        registerSource(source, name, color = false)

    /** Exposes an app-owned ARGB color source. */
    @MainThread
    fun tweakColor(source: TweakSource<Int>, name: String): StateFlow<Int> =
        registerSource(source, name, color = true)

    /** Registers an action without invoking it. Inspector invocations run on main. */
    fun action(name: String, onInvoke: () -> Unit) {
        checkOpen()
        if (TweaksRuntimePolicy.isAllowed) track(TweakRegistry.registerAction(name, onInvoke))
    }

    override fun close() {
        val pending = synchronized(lock) {
            if (closed) return
            closed = true
            resources.toList().asReversed().also { resources.clear() }
        }
        observationJob.cancel()
        closeResources(pending)
    }

    private fun checkOpen() = check(!closed) { "TweakScope is closed." }

    private fun track(resource: Closeable) {
        val dispose = synchronized(lock) {
            if (closed) {
                true
            } else {
                resources.add(resource)
                false
            }
        }
        if (dispose) resource.close()
    }

    private fun <T : Any> register(
        descriptor: TweakDescriptor,
        decode: (Any) -> T,
    ): StateFlow<T> {
        checkOpen()
        if (!TweaksRuntimePolicy.isAllowed) return MutableStateFlow(decode(descriptor.default)).asStateFlow()
        val state = TweakRegistry.register(descriptor)
        track(Closeable { TweakRegistry.unregister(descriptor.name) })
        return observeState(state, decode)
    }

    private fun <T : Any> observeState(
        state: TweakState<Any>,
        decode: (Any) -> T,
        own: (Closeable) -> Unit = ::track,
    ): StateFlow<T> {
        val value = MutableStateFlow(decode(state.value))
        val updateLock = Any()
        fun refresh() = synchronized(updateLock) {
            if (!closed) value.value = decode(state.value)
        }
        own(TweakRegistry.observeChanges { refresh() })
        refresh()
        return value.asStateFlow()
    }

    private fun <T : Any> registerSource(source: TweakSource<T>, name: String, color: Boolean): StateFlow<T> {
        checkOpen()
        if (!TweaksRuntimePolicy.isAllowed) {
            val value = MutableStateFlow(source.value)
            observationScope.launch { source.observe().collect { value.value = source.value } }
            return value.asStateFlow()
        }
        val binding = ScopeSourceBinding(source, name, color)
        val state = TweakRegistry.register(binding) as SelectedTweakState
        val pending = arrayListOf<Closeable>(Closeable { TweakRegistry.unregister(name, binding) })
        var transferred = false
        try {
            val value = observeState(state, binding::decode) { pending.add(it) }
            val selected = MutableStateFlow(state.isSelected(binding))
            pending.add(TweakRegistry.observeChanges { selected.value = state.isSelected(binding) })
            val job = observationScope.launch {
                selected.collectLatest { active ->
                    if (active) source.observe().collect { state.notifyChanged(binding) }
                }
            }
            pending.add(Closeable { job.cancel() })
            transferred = true
            track(Closeable { closeResources(pending.asReversed()) })
            return value
        } finally {
            if (!transferred) closeResources(pending.asReversed())
        }
    }
}

/** Release every registration even if an application-owned cleanup fails. */
@Suppress("TooGenericExceptionCaught")
private fun closeResources(resources: List<Closeable>) {
    var failure: Exception? = null
    resources.forEach { resource ->
        try {
            resource.close()
        } catch (error: Exception) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
    }
    failure?.let { throw it }
}

private class ScopeSourceBinding<T : Any>(
    private val source: TweakSource<T>,
    override val name: String,
    private val color: Boolean,
) : ExternalTweakBacking {
    private val initial by lazy { source.value }
    private var initialValuePending = true
    override val descriptor: TweakDescriptor by lazy {
        val type = when {
            color -> TweakType.COLOR
            initial is Boolean -> TweakType.BOOLEAN
            initial is Int -> TweakType.INT
            initial is Float -> TweakType.FLOAT
            initial is String -> TweakType.STRING
            else -> error("Unsupported tweak value type: ${initial.javaClass.name}")
        }
        TweakDescriptor(name, type, encode(initial))
    }

    override val value: Any
        get() = if (initialValuePending) {
            descriptor.default.also { initialValuePending = false }
        } else {
            encode(source.value)
        }

    override fun onValueChange(value: Any) { source.value = decode(value) }
    override fun onReset() = source.reset()
    override fun isModified(): Boolean = source.isModified

    @Suppress("UNCHECKED_CAST")
    fun decode(value: Any): T = when {
        color -> (value as TweakColorValue).toArgb() as T
        else -> value as T
    }

    private fun encode(value: T): Any = when {
        color -> (value as Int).toTweakColorValue()
        else -> value
    }
}

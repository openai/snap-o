@file:Suppress("TooManyFunctions")

package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.graphics.Color
import com.openai.snapo.tweaks.internal.ExternalTweakBacking
import com.openai.snapo.tweaks.internal.SelectedTweakState
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakState
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest

/**
 * Exposes an application-owned Boolean, Int, Float, String, Color, enum, or BezierCurve tweak.
 *
 * Assigning the returned state writes to the selected source. Make these writes on main.
 * The first observed value is the tool default; edits, resets, and status remain app-owned.
 * Sources with the same name must use the same setting and value type.
 * The first active source handles values, updates, resets, status, and observation.
 * When it leaves, the next active source takes over.
 * Conflicts are not checked and can cause wrong values or runtime errors.
 */
@Composable
fun <T : Any> tweak(
    source: TweakSource<T>,
    name: String,
): MutableState<T> {
    val latestSource = rememberUpdatedState(source)
    if (!TweaksRuntimePolicy.isAllowed) {
        return remember(name) {
            object : MutableState<T> {
                private val revision = mutableIntStateOf(0)

                override var value: T
                    get() {
                        revision.intValue
                        return latestSource.value.value
                    }
                    set(value) {
                        val source = latestSource.value
                        val previous = source.value
                        source.value = value
                        // The source may not read Compose state, so invalidate changed reads explicitly.
                        if (source.value != previous) revision.intValue++
                    }

                override fun component1(): T = value
                override fun component2(): (T) -> Unit = { value = it }
            }
        }
    }

    val registration = remember(name) {
        TweakRegistration(
            ExternalTweakBinding(
                name = name,
                latestSource = latestSource,
            ),
        )
    }

    LaunchedEffect(name, source) { registration.observeSource(source) }

    return registration
}

/** Exposes a cubic curve as one editable value. */
@Composable
fun tweak(
    default: BezierCurve,
    name: String,
): MutableState<BezierCurve> = rememberTweakState(
    TweakDescriptor(name, TweakType.BEZIER, default),
    default,
) { it as BezierCurve }

/** Exposes a floating-point tweak as mutable state. */
@Composable
fun tweak(
    default: Float,
    name: String,
    range: ClosedFloatingPointRange<Float>? = null,
    step: Float? = null,
): MutableState<Float> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.FLOAT,
        default = default,
        min = range?.start,
        max = range?.endInclusive,
        step = step,
    ),
    default = default,
) { value -> value as Float }

/** Exposes an integer tweak as mutable state. */
@Composable
fun tweak(
    default: Int,
    name: String,
    range: IntRange? = null,
    step: Int? = null,
): MutableState<Int> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.INT,
        default = default,
        min = range?.start,
        max = range?.endInclusive,
        step = step,
    ),
    default = default,
) { value -> value as Int }

/** Exposes a color tweak as mutable state. */
@Composable
fun tweak(
    default: Color,
    name: String,
): MutableState<Color> {
    val defaultValue = default.toTweakColorValue()
    return rememberTweakState(
        TweakDescriptor(
            name = name,
            type = TweakType.COLOR,
            default = defaultValue,
        ),
        default = default,
    ) { value -> (value as TweakColorValue).color }
}

/** Exposes a boolean tweak as mutable state. */
@Composable
fun tweak(
    default: Boolean,
    name: String,
): MutableState<Boolean> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.BOOLEAN,
        default = default,
    ),
    default = default,
) { value -> value as Boolean }

/** Exposes a text tweak as mutable state. */
@Composable
fun tweak(
    default: String,
    name: String,
): MutableState<String> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.STRING,
        default = default,
    ),
    default = default,
) { value -> value as String }

/** Exposes every enum constant, in declaration order, as a selection using [Enum.name]. */
@Composable
fun <E : Enum<E>> tweak(
    default: E,
    name: String,
): MutableState<E> {
    if (!TweaksRuntimePolicy.isAllowed) return remember(name, default) { mutableStateOf(default) }

    val enumClass = default.declaringJavaClass
    val descriptor = remember(default, name) { enumTweakDescriptor(default, name) }
    val decode = remember(enumClass) {
        val decoder: (Any) -> E = { value ->
            java.lang.Enum.valueOf(enumClass, value as String)
        }
        decoder
    }

    return rememberTweakState(descriptor, default, decode)
}

internal fun enumTweakDescriptor(
    default: Enum<*>,
    name: String,
): TweakDescriptor = TweakDescriptor(
    name = name,
    type = TweakType.ENUM,
    default = default.name,
    options = requireNotNull(default.declaringJavaClass.enumConstants).map { option ->
        option.name
    },
)

/** Declares a parameterless action while in composition, returning Unit without invoking it. */
@Composable
fun TweakAction(
    name: String,
    onInvoke: () -> Unit,
) {
    if (!TweaksRuntimePolicy.isAllowed) return

    val currentOnInvoke = rememberUpdatedState(onInvoke)
    DisposableEffect(name) {
        val registration = TweakRegistry.registerAction(name) { currentOnInvoke.value() }
        onDispose { registration.close() }
    }
}

@Composable
private fun <T : Any> rememberTweakState(
    descriptor: TweakDescriptor,
    default: T,
    decode: (Any) -> T,
): MutableState<T> = if (TweaksRuntimePolicy.isAllowed) {
    remember(descriptor, decode) {
        TweakRegistration(descriptor, decode)
    }
} else {
    remember(descriptor) { mutableStateOf(default) }
}

internal suspend fun <T : Any> TweakRegistration<T>.observeSource(source: TweakSource<T>) {
    updateObservedSource(source)
    snapshotFlow { isSelected }.collectLatest { selected ->
        if (selected) {
            source.observe().collect { notifyChanged() }
        }
    }
}

internal class TweakRegistration<T : Any> private constructor(
    private val name: String,
    private val descriptor: TweakDescriptor?,
    private val decode: (Any) -> T,
    private val externalBinding: ExternalTweakBinding<T>?,
) : RememberObserver, MutableState<T> {

    constructor(descriptor: TweakDescriptor, decode: (Any) -> T) : this(
        descriptor.name,
        descriptor,
        decode,
        null,
    )

    constructor(externalBinding: ExternalTweakBinding<T>) : this(
        externalBinding.name,
        null,
        externalBinding::decode,
        externalBinding,
    )

    private val state: TweakState<Any> = externalBinding
        ?: TweakRegistry.stateFor(requireNotNull(descriptor))
    private val externalState = externalBinding?.let { mutableStateOf<TweakState<Any>>(it) }
    private var observedSource: TweakSource<T>? = null
    private var registered = false

    private val observedValue = ComposeTweakRegistry.state {
        val current = externalState?.value ?: state
        if (current is SelectedTweakState) {
            @Suppress("UNCHECKED_CAST")
            (current.decode(current.value) as T)
        } else {
            decode(current.value)
        }
    }

    override var value: T
        get() = observedValue.value
        set(value) {
            check(registered) { "Cannot update inactive tweak: $name" }
            val encoded = when (value) {
                is Color -> value.toTweakColorValue()
                is Enum<*> -> value.name
                else -> value
            }
            TweakRegistry.update(mapOf(name to encoded))
        }

    override fun component1(): T = value
    override fun component2(): (T) -> Unit = { value = it }

    val isSelected: Boolean
        get() {
            ComposeTweakRegistry.readRevision()
            return (externalState?.value as? SelectedTweakState)
                ?.isSelected(requireNotNull(externalBinding)) == true
        }

    fun notifyChanged() {
        val binding = externalBinding ?: return
        (externalState?.value as? SelectedTweakState)?.notifyChanged(binding)
    }

    fun updateObservedSource(source: TweakSource<T>) {
        val previous = observedSource
        observedSource = source
        if (previous !== null && previous !== source && isSelected) notifyChanged()
    }

    override fun onRemembered() {
        if (!registered) {
            if (externalBinding == null) {
                TweakRegistry.register(requireNotNull(descriptor))
            } else {
                val registeredState = TweakRegistry.register(externalBinding)
                requireNotNull(externalState).value = registeredState
            }
            registered = true
        }
    }

    override fun onForgotten() = unregister()

    override fun onAbandoned() = unregister()

    private fun unregister() {
        if (registered) {
            TweakRegistry.unregister(name, externalBinding)
            registered = false
        }
    }
}

internal class ExternalTweakBinding<T : Any>(
    override val name: String,
    private val latestSource: State<TweakSource<T>>,
) : ExternalTweakBacking {

    private val initial by lazy { latestSource.value.value }
    private var initialValuePending = true

    override val descriptor: TweakDescriptor by lazy {
        val initial = initial
        if (initial is Enum<*>) return@lazy enumTweakDescriptor(initial, name)
        TweakDescriptor(
            name = name,
            type = when (initial) {
                is Boolean -> TweakType.BOOLEAN
                is Int -> TweakType.INT
                is Float -> TweakType.FLOAT
                is String -> TweakType.STRING
                is Color -> TweakType.COLOR
                is BezierCurve -> TweakType.BEZIER
                else -> throw IllegalArgumentException(
                    "Unsupported tweak value type: ${initial.javaClass.name}. " +
                        "Supported types are Boolean, Int, Float, String, Color, enum, and BezierCurve.",
                )
            },
            default = encode(initial),
        )
    }

    override val value: Any
        get() = synchronized(this) {
            val initial = descriptor.default
            if (initialValuePending) {
                initialValuePending = false
                initial
            } else {
                encode(latestSource.value.value)
            }
        }

    override fun onValueChange(value: Any) {
        latestSource.value.value = decode(value)
    }

    override fun onReset() {
        latestSource.value.reset()
    }

    override fun isModified(): Boolean = latestSource.value.isModified

    @Suppress("UNCHECKED_CAST")
    override fun decode(value: Any): T = when (val initial = initial) {
        is Enum<*> -> java.lang.Enum.valueOf(initial.declaringJavaClass, value as String) as T
        else -> if (value is TweakColorValue) value.color as T else value as T
    }

    private fun encode(value: T): Any = when (value) {
        is Color -> value.toTweakColorValue()
        is Enum<*> -> value.name
        else -> value
    }
}

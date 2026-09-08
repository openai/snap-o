package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.graphics.Color
import com.openai.snapo.tweaks.internal.ExternalTweakBacking
import com.openai.snapo.tweaks.internal.SelectedTweakState
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest

/**
 * Exposes an application-owned Boolean, Int, Float, String, or Color tweak.
 *
 * The first observed value is the inspector default; edits, resets, and status remain app-owned.
 * Sources with the same name must use the same setting and value type.
 * The first active source handles values, updates, resets, status, and observation.
 * When it leaves, the next active source takes over.
 * Conflicts are not checked and can cause wrong values or runtime errors.
 */
@Composable
fun <T : Any> tweak(
    source: TweakSource<T>,
    name: String,
): State<T> {
    val latestSource = rememberUpdatedState(source)
    if (!TweaksRuntimePolicy.isAllowed) {
        return remember(name) {
            object : State<T> {
                override val value: T
                    get() = latestSource.value.value
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

/** Exposes a floating-point tweak as observable state. */
@Composable
fun tweak(
    default: Float,
    name: String,
    range: ClosedFloatingPointRange<Float>? = null,
    step: Float? = null,
): State<Float> = rememberTweakState(
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

/** Exposes an integer tweak as observable state. */
@Composable
fun tweak(
    default: Int,
    name: String,
    range: IntRange? = null,
    step: Int? = null,
): State<Int> = rememberTweakState(
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

/** Exposes a color tweak as observable state. */
@Composable
fun tweak(
    default: Color,
    name: String,
): State<Color> {
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

/** Exposes a boolean tweak as observable state. */
@Composable
fun tweak(
    default: Boolean,
    name: String,
): State<Boolean> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.BOOLEAN,
        default = default,
    ),
    default = default,
) { value -> value as Boolean }

/** Exposes a text tweak as observable state. */
@Composable
fun tweak(
    default: String,
    name: String,
): State<String> = rememberTweakState(
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
): State<E> {
    if (!TweaksRuntimePolicy.isAllowed) return rememberUpdatedState(default)

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

internal fun <E : Enum<E>> enumTweakDescriptor(
    default: E,
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
): State<T> = if (TweaksRuntimePolicy.isAllowed) {
    remember(descriptor, decode) {
        TweakRegistration(descriptor, decode)
    }
} else {
    rememberUpdatedState(default)
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
) : RememberObserver, State<T> {

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

    private val state: State<Any> = externalBinding
        ?: TweakRegistry.stateFor(requireNotNull(descriptor))
    private val externalState = externalBinding?.let { mutableStateOf<State<Any>>(it) }
    private var observedSource: TweakSource<T>? = null
    private var registered = false

    override val value: T
        get() = decode((externalState?.value ?: state).value)

    val isSelected: Boolean
        get() = (externalState?.value as? SelectedTweakState)
            ?.isSelected(requireNotNull(externalBinding)) == true

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

    private var initialValuePending = true

    override val descriptor: TweakDescriptor by lazy {
        val initial = latestSource.value.value
        TweakDescriptor(
            name = name,
            type = when (initial) {
                is Boolean -> TweakType.BOOLEAN
                is Int -> TweakType.INT
                is Float -> TweakType.FLOAT
                is String -> TweakType.STRING
                is Color -> TweakType.COLOR
                else -> throw IllegalArgumentException(
                    "Unsupported tweak value type: ${initial.javaClass.name}. " +
                        "Supported types are Boolean, Int, Float, String, and Color.",
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
    fun decode(value: Any): T =
        if (value is TweakColorValue) value.color as T else value as T

    private fun encode(value: T): Any =
        if (value is Color) value.toTweakColorValue() else value
}

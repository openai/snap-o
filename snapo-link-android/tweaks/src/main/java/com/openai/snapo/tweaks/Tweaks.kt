package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.Color
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy

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
private fun <T> rememberTweakState(
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

internal class TweakRegistration<T>(
    private val descriptor: TweakDescriptor,
    private val decode: (Any) -> T,
) : RememberObserver, State<T> {

    private val state: State<Any> = TweakRegistry.stateFor(descriptor)
    private var registered = false

    override val value: T
        get() = decode(state.value)

    override fun onRemembered() {
        if (!registered) {
            TweakRegistry.register(descriptor)
            registered = true
        }
    }

    override fun onForgotten() = unregister()

    override fun onAbandoned() = unregister()

    private fun unregister() {
        if (registered) {
            TweakRegistry.unregister(descriptor.name)
            registered = false
        }
    }
}

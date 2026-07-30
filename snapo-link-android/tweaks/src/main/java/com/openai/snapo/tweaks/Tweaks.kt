package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
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
fun tweakFloat(
    name: String,
    default: Float,
    min: Float? = null,
    max: Float? = null,
    step: Float? = null,
): State<Float> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.FLOAT,
        default = default,
        min = min,
        max = max,
        step = step,
    ),
    default = default,
) { value -> value as Float }

/** Exposes an integer tweak as observable state. */
@Composable
fun tweakInt(
    name: String,
    default: Int,
    min: Int? = null,
    max: Int? = null,
    step: Int? = null,
): State<Int> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.INT,
        default = default,
        min = min,
        max = max,
        step = step,
    ),
    default = default,
) { value -> value as Int }

/** Exposes a color tweak as observable state. */
@Composable
fun tweakColor(
    name: String,
    default: Color,
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
fun tweakBoolean(
    name: String,
    default: Boolean,
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
fun tweakString(
    name: String,
    default: String,
): State<String> = rememberTweakState(
    TweakDescriptor(
        name = name,
        type = TweakType.STRING,
        default = default,
    ),
    default = default,
) { value -> value as String }

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

package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.RememberObserver
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.toArgb
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy

/** Exposes a floating-point tweak as observable state. */
@Composable
fun tweak(
    default: Float,
    name: String,
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
fun tweak(
    default: Int,
    name: String,
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
fun tweak(
    default: Color,
    name: String,
): State<Color> {
    val encodedDefault = default.toTweakColor()
    return rememberTweakState(
        TweakDescriptor(
            name = name,
            type = TweakType.COLOR,
            default = encodedDefault,
        ),
        default = default,
    ) { value ->
        decodeTweakColor(value, default, encodedDefault)
    }
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

internal fun decodeTweakColor(
    value: Any,
    default: Color,
    encodedDefault: String,
): Color {
    val encodedValue = value as String

    return if (encodedValue == encodedDefault) {
        default
    } else {
        encodedValue.toTweakColor()
    }
}

internal fun Color.toTweakColor(): String {
    val argb = if (isSpecified) toArgb() else 0
    val redGreenBlue = (argb and 0x00FF_FFFF)
        .toString(radix = 16)
        .padStart(length = 6, padChar = '0')
        .uppercase()
    val alpha = argb ushr 24

    return if (alpha == 0xFF) {
        "#$redGreenBlue"
    } else {
        val alphaHex = alpha
            .toString(radix = 16)
            .padStart(length = 2, padChar = '0')
            .uppercase()
        "#$redGreenBlue$alphaHex"
    }
}

internal fun String.toTweakColor(): Color {
    require(startsWith('#')) { "Tweak colors must start with #." }

    val digits = substring(startIndex = 1)
    val argb = when (digits.length) {
        6 -> 0xFF00_0000L or digits.toLong(radix = 16)
        8 -> {
            val rgba = digits.toLong(radix = 16)
            val alpha = rgba and 0xFF
            (alpha shl 24) or (rgba ushr 8)
        }

        else -> error("Tweak colors must use #RRGGBB or #RRGGBBAA.")
    }

    return Color(argb.toInt())
}

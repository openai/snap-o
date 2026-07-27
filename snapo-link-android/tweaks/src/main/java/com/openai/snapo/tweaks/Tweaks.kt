package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType

/** Exposes a floating-point value to Snap-O Tweaks. */
@Composable
fun tweakFloat(
    name: String,
    default: Float,
    min: Float? = null,
    max: Float? = null,
    step: Float? = null,
): Float = rememberTweakValue(
    TweakDescriptor(
        name = name,
        type = TweakType.FLOAT,
        default = default,
        min = min,
        max = max,
        step = step,
    ),
) { value -> value as Float }

/** Exposes an integer value to Snap-O Tweaks. */
@Composable
fun tweakInt(
    name: String,
    default: Int,
    min: Int? = null,
    max: Int? = null,
    step: Int? = null,
): Int = rememberTweakValue(
    TweakDescriptor(
        name = name,
        type = TweakType.INT,
        default = default,
        min = min,
        max = max,
        step = step,
    ),
) { value -> value as Int }

/** Exposes a color as an RGB or RGBA hexadecimal string. */
@Composable
fun tweakColor(
    name: String,
    default: Color,
): Color = rememberTweakValue(
    TweakDescriptor(
        name = name,
        type = TweakType.COLOR,
        default = default.toTweakColor(),
    ),
) { value -> (value as String).toTweakColor() }

/** Exposes a boolean value to Snap-O Tweaks. */
@Composable
fun tweakBoolean(
    name: String,
    default: Boolean,
): Boolean = rememberTweakValue(
    TweakDescriptor(
        name = name,
        type = TweakType.BOOLEAN,
        default = default,
    ),
) { value -> value as Boolean }

/** Exposes a text value to Snap-O Tweaks. */
@Composable
fun tweakString(
    name: String,
    default: String,
): String = rememberTweakValue(
    TweakDescriptor(
        name = name,
        type = TweakType.STRING,
        default = default,
    ),
) { value -> value as String }

@Composable
private fun <T> rememberTweakValue(
    descriptor: TweakDescriptor,
    decode: (Any) -> T,
): T {
    val registeredState = remember(descriptor) {
        mutableStateOf<State<Any>?>(null)
    }

    DisposableEffect(descriptor) {
        registeredState.value = TweakRegistry.register(descriptor)

        onDispose {
            TweakRegistry.unregister(descriptor.name)
        }
    }

    return decode(registeredState.value?.value ?: descriptor.default)
}

private fun Color.toTweakColor(): String {
    val argb = toArgb()
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

private fun String.toTweakColor(): Color {
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

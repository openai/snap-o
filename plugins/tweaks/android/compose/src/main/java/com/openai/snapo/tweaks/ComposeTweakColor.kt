package com.openai.snapo.tweaks

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.toArgb

internal val TweakColorValue.color: Color
    get() = original as? Color ?: Color(toArgb())

internal fun Color.toTweakColorValue(): TweakColorValue =
    TweakColorValue(
        original = if (isSpecified && this == Color(toArgbSafely())) toArgbSafely() else this,
        wireValue = toTweakColor(),
    )

internal fun Color.toTweakColor(): String {
    val argb = if (isSpecified) {
        toArgbSafely()
    } else {
        0
    }
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

private fun Color.toArgbSafely(): Int =
    runCatching { toArgb() }.getOrElse { error ->
        if (error !is RuntimeException) throw error
        unsupportedTweakColor(error)
    }

private fun unsupportedTweakColor(error: RuntimeException): Nothing =
    throw IllegalArgumentException(
        "Tweak colors must be Color.Unspecified or convertible to sRGB.",
        error,
    )

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

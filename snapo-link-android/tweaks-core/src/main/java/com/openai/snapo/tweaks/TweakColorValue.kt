package com.openai.snapo.tweaks

import androidx.annotation.RestrictTo

/** Keeps an adapter's exact color identity separate from the sRGB wire representation. */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
data class TweakColorValue(val original: Any, val wireValue: String)

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun Int.toTweakColorValue(): TweakColorValue {
    val rgb = (this and 0x00FF_FFFF).toString(16).padStart(6, '0').uppercase()
    val alpha = this ushr 24
    val suffix = if (alpha == 255) "" else alpha.toString(16).padStart(2, '0').uppercase()
    return TweakColorValue(this, "#$rgb$suffix")
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun String.toTweakColorValue(): TweakColorValue {
    require(startsWith('#')) { "Tweak colors must start with #." }
    val digits = substring(1)
    val argb = when (digits.length) {
        6 -> 0xFF00_0000L or digits.toLong(16)
        8 -> digits.toLong(16).let { rgba -> ((rgba and 0xFF) shl 24) or (rgba ushr 8) }
        else -> error("Tweak colors must use #RRGGBB or #RRGGBBAA.")
    }
    return TweakColorValue(argb.toInt(), uppercase())
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun TweakColorValue.toArgb(): Int = original as? Int
    ?: (wireValue.toTweakColorValue().original as Int)

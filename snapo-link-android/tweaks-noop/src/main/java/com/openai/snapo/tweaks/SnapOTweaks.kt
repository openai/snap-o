@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.tweaks

import androidx.annotation.RestrictTo
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.Color

/** Keeps tweak observation inactive in no-op builds. */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
object SnapOTweaks {

    private val emptyEntries: State<List<SnapOTweakEntry>> = mutableStateOf(emptyList())

    /** No observable tweaks are registered in a no-op build. */
    fun activeTweakEntries(): State<List<SnapOTweakEntry>> = emptyEntries

    /** No tweaks are registered in a no-op build. */
    internal fun activeTweaks(): List<SnapOTweak> = emptyList()

    /** Ignores tweak updates in a no-op build. */
    fun update(name: String, value: SnapOTweakValue) = Unit
}

/** The matching observable tweak shape from the live implementation. */
@Stable
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
class SnapOTweakEntry internal constructor(
    val name: String,
    val value: State<SnapOTweakValue>,
    val defaultValue: SnapOTweakValue,
)

/** A tweak value exposed by the matching live implementation. */
@Immutable
internal data class SnapOTweak(
    val name: String,
    val value: SnapOTweakValue,
    val defaultValue: SnapOTweakValue,
)

/** A typed tweak value and its optional presentation constraints. */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
sealed interface SnapOTweakValue {

    @Immutable
    @RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
    data class Integer(
        val value: Int,
        val min: Int? = null,
        val max: Int? = null,
        val step: Int = 1,
    ) : SnapOTweakValue

    @Immutable
    @RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
    data class Floating(
        val value: Float,
        val min: Float? = null,
        val max: Float? = null,
        val step: Float? = null,
    ) : SnapOTweakValue

    @Immutable
    @RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
    data class Toggle(val value: Boolean) : SnapOTweakValue

    @Immutable
    @RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
    data class ColorValue(val value: Color) : SnapOTweakValue

    @Immutable
    @RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
    data class Text(val value: String) : SnapOTweakValue

    @Immutable
    @RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
    data class Selection(
        val value: String,
        val options: List<String>,
    ) : SnapOTweakValue
}

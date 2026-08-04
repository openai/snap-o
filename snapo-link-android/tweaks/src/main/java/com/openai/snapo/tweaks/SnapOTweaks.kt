package com.openai.snapo.tweaks

import androidx.annotation.RestrictTo
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.ui.graphics.Color
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakSnapshot
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy

/** Observes and updates the tweaks currently registered by composition. */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
object SnapOTweaks {

    /** Returns observable active tweaks in the order in which they entered composition. */
    fun activeTweakEntries(): State<List<SnapOTweakEntry>> = TweakRegistry.activeEntries()

    /** Returns active tweaks in the order in which they entered composition. */
    internal fun activeTweaks(): List<SnapOTweak> = TweakRegistry.snapshot().map { snapshot ->
        snapshot.toSnapOTweak()
    }

    /** Updates an active tweak through the same registry used by the host inspector. */
    fun update(name: String, value: SnapOTweakValue) {
        if (!TweaksRuntimePolicy.isAllowed) return

        TweakRegistry.update(mapOf(name to value.toRegistryValue()))
    }
}

/** A stable active tweak whose current value can be observed independently. */
@Stable
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
class SnapOTweakEntry internal constructor(
    val name: String,
    val value: State<SnapOTweakValue>,
    val defaultValue: SnapOTweakValue,
)

/** A tweak currently available in the composed application. */
@Immutable
internal data class SnapOTweak(
    val name: String,
    val value: SnapOTweakValue,
    val defaultValue: SnapOTweakValue,
)

/** A typed tweak value and the constraints needed to present it. */
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

private fun TweakSnapshot.toSnapOTweak(): SnapOTweak = SnapOTweak(
    name = descriptor.name,
    value = descriptor.toSnapOTweakValue(value),
    defaultValue = descriptor.toSnapOTweakValue(descriptor.default),
)

internal fun TweakDescriptor.toSnapOTweakValue(value: Any): SnapOTweakValue = when (type) {
    TweakType.INT -> SnapOTweakValue.Integer(
        value = value as Int,
        min = min as Int?,
        max = max as Int?,
        step = step as Int? ?: 1,
    )

    TweakType.FLOAT -> SnapOTweakValue.Floating(
        value = value as Float,
        min = min as Float?,
        max = max as Float?,
        step = step as Float?,
    )

    TweakType.BOOLEAN -> SnapOTweakValue.Toggle(value as Boolean)
    TweakType.COLOR -> SnapOTweakValue.ColorValue((value as TweakColorValue).color)
    TweakType.STRING -> SnapOTweakValue.Text(value as String)
    TweakType.ENUM -> SnapOTweakValue.Selection(value as String, options)
}

private fun SnapOTweakValue.toRegistryValue(): Any = when (this) {
    is SnapOTweakValue.Integer -> value
    is SnapOTweakValue.Floating -> value
    is SnapOTweakValue.Toggle -> value
    is SnapOTweakValue.ColorValue -> value.toTweakColorValue()
    is SnapOTweakValue.Text -> value
    is SnapOTweakValue.Selection -> value
}

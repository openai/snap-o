package com.openai.snapo.tweaks.internal

import androidx.annotation.RestrictTo

/** Lazy registry reads used by the platform adapters. Applications use StateFlow. */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
interface TweakState<out T> {
    val value: T
}

internal class MutableTweakState<T>(initial: T) : TweakState<T> {
    @Volatile
    override var value: T = initial
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
class CoreTweakEntry(
    val name: String,
    val state: TweakState<Any>,
    descriptor: () -> TweakDescriptor,
    val isModified: () -> Boolean,
) {
    val descriptor: TweakDescriptor by lazy(descriptor)
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
data class TweakActionValue(val conflicted: Boolean = false)

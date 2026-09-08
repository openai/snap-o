package com.openai.snapo.tweaks.internal

import androidx.annotation.RestrictTo

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
object TweaksRuntimePolicy {

    @Volatile
    var isAllowed: Boolean = false
        private set

    fun configure(
        isDebuggable: Boolean,
        allowRelease: Boolean,
    ): Boolean {
        val allowed = isDebuggable || allowRelease
        isAllowed = allowed
        return allowed
    }
}

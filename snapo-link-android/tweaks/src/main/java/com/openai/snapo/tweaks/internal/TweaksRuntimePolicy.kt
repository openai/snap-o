package com.openai.snapo.tweaks.internal

internal object TweaksRuntimePolicy {

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

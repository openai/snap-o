package com.openai.snapo.tweaks.internal

import androidx.annotation.RestrictTo
import com.openai.snapo.plugin.PluginStartupPolicy

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
object TweaksRuntimePolicy {

    @Volatile
    var isAllowed: Boolean = false
        private set

    fun configure(
        isDebuggable: Boolean,
        allowRelease: Boolean,
    ): Boolean = configureAllowed(PluginStartupPolicy.isAllowed(isDebuggable, allowRelease))

    internal fun configureAllowed(allowed: Boolean): Boolean {
        isAllowed = allowed
        return allowed
    }
}

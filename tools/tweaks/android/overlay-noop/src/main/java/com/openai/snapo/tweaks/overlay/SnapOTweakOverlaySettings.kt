package com.openai.snapo.tweaks.overlay

/** Keeps the floating tweak overlay disabled in no-op builds. */
object SnapOTweakOverlaySettings {

    /** The floating tweak overlay is never enabled in a no-op build. */
    var isEnabled: Boolean
        get() = false
        set(@Suppress("UNUSED_PARAMETER") value) = Unit
}

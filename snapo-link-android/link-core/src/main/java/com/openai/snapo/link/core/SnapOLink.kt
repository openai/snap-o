package com.openai.snapo.link.core

/**
 * Process-local entry point for the Snap-O link.
 * [SnapOInitProvider] will call [attach] when auto-init is enabled.
 */
object SnapOLink {

    @Volatile
    private var serverRef: SnapOLinkServer? = null

    internal fun attach(server: SnapOLinkServer) {
        serverRef = server
    }

    /** Returns the active server in this process, or null if the link is disabled. */
    fun serverOrNull(): SnapOLinkServer? = serverRef

    /** True if the link is active in this process. */
    fun isEnabled(): Boolean = serverRef != null
}

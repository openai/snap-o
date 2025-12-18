package com.openai.snapo.link.core

object SnapOLinkRegistry {
    private val lock = Any()
    private val features = LinkedHashSet<SnapOLinkFeature>()

    fun register(feature: SnapOLinkFeature) {
        synchronized(lock) { features.add(feature) }
    }

    fun snapshot(): List<SnapOLinkFeature> = synchronized(lock) { features.toList() }
}

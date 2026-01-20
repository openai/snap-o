package com.openai.snapo.link.core

object SnapOLinkRegistry {
    private val lock = Any()
    private val features = LinkedHashMap<String, SnapOLinkFeature>()
    private val linkedFeatureIds = HashSet<String>()
    private var sinkProvider: ((String) -> LinkEventSink)? = null

    fun register(feature: SnapOLinkFeature) {
        val (storedFeature, provider) = synchronized(lock) {
            val existing = features.putIfAbsent(feature.featureId, feature)
            Pair(existing ?: feature, sinkProvider)
        }
        if (provider != null) {
            linkFeatureIfNeeded(storedFeature, provider)
        }
    }

    internal fun bindSinkProvider(provider: (String) -> LinkEventSink) {
        val snapshot = synchronized(lock) {
            sinkProvider = provider
            features.values.toList()
        }
        snapshot.forEach { linkFeatureIfNeeded(it, provider) }
    }

    fun snapshot(): List<SnapOLinkFeature> =
        synchronized(lock) { features.values.toList() }

    private fun linkFeatureIfNeeded(
        feature: SnapOLinkFeature,
        provider: (String) -> LinkEventSink,
    ) {
        val shouldLink = synchronized(lock) {
            if (linkedFeatureIds.contains(feature.featureId)) return@synchronized false
            linkedFeatureIds.add(feature.featureId)
            true
        }
        if (shouldLink) {
            feature.onLinkAvailable(provider(feature.featureId))
        }
    }
}

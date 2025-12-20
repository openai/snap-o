package com.openai.snapo.link.core

import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.serializer

interface SnapOLinkFeature {
    /** Stable identifier used for feature envelopes. */
    val featureId: String

    suspend fun onClientConnected(sink: LinkEventSink)
    suspend fun onFeatureOpened()
    fun onClientDisconnected()
}

interface LinkEventSink {
    suspend fun <T> sendHighPriority(payload: T, serializer: SerializationStrategy<T>)
    suspend fun <T> sendLowPriority(payload: T, serializer: SerializationStrategy<T>)
}

suspend inline fun <reified T> LinkEventSink.sendHighPriority(payload: T) {
    sendHighPriority(payload, serializer())
}

suspend inline fun <reified T> LinkEventSink.sendLowPriority(payload: T) {
    sendLowPriority(payload, serializer())
}

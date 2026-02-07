package com.openai.snapo.link.core

import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.serializer

interface SnapOLinkFeature {
    /** Stable identifier used for feature envelopes. */
    val featureId: String

    /** Called once when the link server is available so features can broadcast or target clients. */
    fun onLinkAvailable(sink: LinkEventSink) {}

    /** Invoked once per client session when a client opens this feature. */
    suspend fun onFeatureOpened(clientId: Long)

    /** Invoked for host-originated commands targeting this feature. */
    suspend fun onFeatureCommand(clientId: Long, payload: JsonElement) {}

    /** Invoked when a client disconnects. */
    fun onClientDisconnected(clientId: Long) {}
}

sealed interface ClientId {
    data object All : ClientId
    data class Specific(val value: Long) : ClientId
}

enum class EventPriority {
    High,
    Low,
}

interface LinkEventSink {
    fun <T> send(
        payload: T,
        serializer: SerializationStrategy<T>,
        clientId: ClientId = ClientId.All,
        priority: EventPriority = EventPriority.High,
    )
}

inline fun <reified T> LinkEventSink.send(
    payload: T,
    clientId: ClientId = ClientId.All,
    priority: EventPriority = EventPriority.High,
) {
    send(payload, serializer(), clientId, priority)
}

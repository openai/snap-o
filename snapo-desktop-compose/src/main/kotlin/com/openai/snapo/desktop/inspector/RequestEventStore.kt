package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.protocol.RequestFailed
import com.openai.snapo.desktop.protocol.RequestWillBeSent
import com.openai.snapo.desktop.protocol.ResponseReceived
import com.openai.snapo.desktop.protocol.ResponseStreamClosed
import com.openai.snapo.desktop.protocol.ResponseStreamEvent
import com.openai.snapo.desktop.protocol.SnapONetRecord
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

internal class RequestEventStore {
    private val mutex = Mutex()
    private val requestStates = HashMap<NetworkInspectorRequestId, NetworkInspectorRequest>()
    private val requestOrder = ArrayList<NetworkInspectorRequestId>()

    private val _requests = MutableStateFlow<List<NetworkInspectorRequest>>(emptyList())
    val requests: StateFlow<List<NetworkInspectorRequest>> = _requests.asStateFlow()

    suspend fun handle(serverId: SnapOLinkServerId, payload: SnapONetRecord): Boolean {
        return when (payload) {
            is RequestWillBeSent -> {
                updateRequest(serverId, payload)
                true
            }
            is ResponseReceived -> {
                updateRequest(serverId, payload)
                true
            }
            is RequestFailed -> {
                updateRequest(serverId, payload)
                true
            }
            is ResponseStreamEvent -> {
                updateRequest(serverId, payload)
                true
            }
            is ResponseStreamClosed -> {
                updateRequest(serverId, payload)
                true
            }
            else -> false
        }
    }

    suspend fun clearCompletedEntries() {
        mutex.withLock {
            val retained = requestStates.filterValues { request ->
                when {
                    request.failure != null -> false
                    request.streamClosed != null -> false
                    request.streamEvents.isNotEmpty() -> true
                    request.isLikelyStreamingResponse -> true
                    else -> request.response == null
                }
            }
            requestStates.clear()
            requestStates.putAll(retained)
            requestOrder.retainAll(retained.keys)
            broadcastRequestsLocked()
        }
    }

    suspend fun removeServer(serverId: SnapOLinkServerId) {
        mutex.withLock {
            requestOrder.removeAll { it.serverId == serverId }
            val toRemove = requestStates.keys.filter { it.serverId == serverId }
            for (key in toRemove) requestStates.remove(key)
            broadcastRequestsLocked()
        }
    }

    private suspend fun updateRequest(serverId: SnapOLinkServerId, record: RequestWillBeSent) {
        val now = Instant.now()
        val id = NetworkInspectorRequestId(serverId = serverId, requestId = record.id)

        mutex.withLock {
            val existing = requestStates[id]
            val updated = if (existing == null) {
                NetworkInspectorRequest(
                    serverId = serverId,
                    requestId = record.id,
                    request = record,
                    response = null,
                    failure = null,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }
            } else {
                existing.copy(
                    request = record,
                    failure = null,
                    lastUpdatedAt = now,
                )
            }

            requestStates[id] = updated
            broadcastRequestsLocked()
        }
    }

    private suspend fun updateRequest(serverId: SnapOLinkServerId, record: ResponseReceived) {
        val now = Instant.now()
        val id = NetworkInspectorRequestId(serverId = serverId, requestId = record.id)

        mutex.withLock {
            val existing = requestStates[id]
            val updated = if (existing == null) {
                NetworkInspectorRequest(
                    serverId = serverId,
                    requestId = record.id,
                    request = null,
                    response = record,
                    failure = null,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }
            } else {
                existing.copy(
                    response = record,
                    failure = null,
                    lastUpdatedAt = now,
                )
            }

            requestStates[id] = updated
            broadcastRequestsLocked()
        }
    }

    private suspend fun updateRequest(serverId: SnapOLinkServerId, record: RequestFailed) {
        val now = Instant.now()
        val id = NetworkInspectorRequestId(serverId = serverId, requestId = record.id)

        mutex.withLock {
            val existing = requestStates[id]
            val updated = if (existing == null) {
                NetworkInspectorRequest(
                    serverId = serverId,
                    requestId = record.id,
                    request = null,
                    response = null,
                    failure = record,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }
            } else {
                existing.copy(
                    failure = record,
                    response = null,
                    lastUpdatedAt = now,
                )
            }

            requestStates[id] = updated
            broadcastRequestsLocked()
        }
    }

    private suspend fun updateRequest(serverId: SnapOLinkServerId, record: ResponseStreamEvent) {
        val now = Instant.now()
        val id = NetworkInspectorRequestId(serverId = serverId, requestId = record.id)

        mutex.withLock {
            val existing = requestStates[id]
                ?: NetworkInspectorRequest(
                    serverId = serverId,
                    requestId = record.id,
                    request = null,
                    response = null,
                    failure = null,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }

            val events = existing.streamEvents.toMutableList()
            val index = events.indexOfFirst { it.sequence == record.sequence }
            if (index >= 0) {
                events[index] = record
            } else {
                events.add(record)
            }
            events.sortWith(compareBy<ResponseStreamEvent> { it.sequence }.thenBy { it.tWallMs })

            requestStates[id] = existing.copy(
                streamEvents = events,
                lastUpdatedAt = now,
            )
            broadcastRequestsLocked()
        }
    }

    private suspend fun updateRequest(serverId: SnapOLinkServerId, record: ResponseStreamClosed) {
        val now = Instant.now()
        val id = NetworkInspectorRequestId(serverId = serverId, requestId = record.id)

        mutex.withLock {
            val existing = requestStates[id]
                ?: NetworkInspectorRequest(
                    serverId = serverId,
                    requestId = record.id,
                    request = null,
                    response = null,
                    failure = null,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }

            requestStates[id] = existing.copy(
                streamClosed = record,
                lastUpdatedAt = now,
            )
            broadcastRequestsLocked()
        }
    }

    private fun broadcastRequestsLocked() {
        _requests.value = requestOrder.mapNotNull { requestStates[it] }
    }
}

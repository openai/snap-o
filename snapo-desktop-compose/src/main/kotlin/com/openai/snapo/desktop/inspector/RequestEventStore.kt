package com.openai.snapo.desktop.inspector

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

    suspend fun handle(serverId: SnapOLinkServerId, payload: NetworkEventRecord): Boolean {
        return when (payload) {
            is RequestWillBeSent -> {
                updateRequest(serverId, payload)
                true
            }
            is ResponseReceived -> {
                updateRequest(serverId, payload)
                true
            }
            is ResponseFinished -> {
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
                    request.response != null && request.finished != null -> false
                    else -> true
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

    suspend fun shouldRequestRequestBody(id: NetworkInspectorRequestId): Boolean {
        return mutex.withLock {
            val state = requestStates[id] ?: return@withLock false
            val request = state.request ?: return@withLock false
            if (!request.body.isNullOrEmpty()) return@withLock false
            // null means unknown size; still try.
            val size = request.bodySize
            size == null || size != 0L
        }
    }

    suspend fun shouldRequestResponseBody(id: NetworkInspectorRequestId): Boolean {
        return mutex.withLock {
            val state = requestStates[id] ?: return@withLock false
            if (state.streamEvents.isNotEmpty() || state.isLikelyStreamingResponse) {
                if (state.streamClosed == null) return@withLock false
                val response = state.response
                if (response == null) return@withLock true
                if (!response.body.isNullOrEmpty()) return@withLock false
                val size = response.bodySize
                return@withLock size == null || size != 0L
            }

            if (state.finished == null) return@withLock false
            val response = state.response ?: return@withLock false
            if (responseHasNoBody(state = state, response = response)) return@withLock false
            if (!response.body.isNullOrEmpty()) return@withLock false
            // null means unknown size; still try.
            val size = response.bodySize
            size == null || size != 0L
        }
    }

    suspend fun applyRequestBody(
        id: NetworkInspectorRequestId,
        body: String,
    ) {
        val now = Instant.now()
        mutex.withLock {
            val existing = requestStates[id] ?: return@withLock
            val request = existing.request ?: return@withLock
            if (request.body == body) return@withLock
            requestStates[id] = existing.copy(
                request = request.copy(body = body),
                lastUpdatedAt = now,
            )
            broadcastRequestsLocked()
        }
    }

    suspend fun applyResponseBody(
        id: NetworkInspectorRequestId,
        body: String,
        base64Encoded: Boolean,
    ) {
        val now = Instant.now()
        mutex.withLock {
            val existing = requestStates[id] ?: return@withLock
            val response = existing.response ?: return@withLock
            if (response.body == body && response.bodyBase64Encoded == base64Encoded) return@withLock
            requestStates[id] = existing.copy(
                response = response.copy(
                    body = body,
                    bodyBase64Encoded = base64Encoded,
                ),
                lastUpdatedAt = now,
            )
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
                    finished = null,
                    failure = null,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }
            } else {
                existing.copy(
                    request = record,
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
                    finished = null,
                    failure = null,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }
            } else {
                existing.copy(
                    response = record,
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
                    finished = null,
                    failure = record,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }
            } else {
                existing.copy(
                    failure = record,
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
                    finished = null,
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
                    finished = null,
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

    private suspend fun updateRequest(serverId: SnapOLinkServerId, record: ResponseFinished) {
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
                    finished = record,
                    failure = null,
                    streamEvents = emptyList(),
                    streamClosed = null,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { requestOrder.add(id) }
            } else {
                existing.copy(
                    finished = record,
                    lastUpdatedAt = now,
                )
            }

            requestStates[id] = updated
            broadcastRequestsLocked()
        }
    }

    private fun broadcastRequestsLocked() {
        _requests.value = requestOrder.mapNotNull { requestStates[it] }
    }

    private fun responseHasNoBody(
        state: NetworkInspectorRequest,
        response: ResponseReceived,
    ): Boolean {
        val contentLength = response.headers
            .firstOrNull { header -> header.name.equals("Content-Length", ignoreCase = true) }
            ?.value
            ?.trim()
            ?.toLongOrNull()
        return responseIsDefinedAsBodyless(
            requestMethod = state.request?.method,
            responseStatus = response.code,
            responseContentLength = contentLength,
        )
    }
}

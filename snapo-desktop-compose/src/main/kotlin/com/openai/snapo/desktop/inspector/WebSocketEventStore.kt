package com.openai.snapo.desktop.inspector

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

internal class WebSocketEventStore {
    private val mutex = Mutex()
    private val webSocketStates = HashMap<NetworkInspectorWebSocketId, NetworkInspectorWebSocket>()
    private val webSocketOrder = ArrayList<NetworkInspectorWebSocketId>()

    private val _webSockets = MutableStateFlow<List<NetworkInspectorWebSocket>>(emptyList())
    val webSockets: StateFlow<List<NetworkInspectorWebSocket>> = _webSockets.asStateFlow()

    suspend fun handle(serverId: SnapOLinkServerId, payload: NetworkEventRecord) {
        when (payload) {
            is WebSocketWillOpen -> updateWebSocket(serverId, payload)
            is WebSocketOpened -> updateWebSocket(serverId, payload)
            is WebSocketMessageSent -> updateWebSocket(serverId, payload)
            is WebSocketMessageReceived -> updateWebSocket(serverId, payload)
            is WebSocketClosing -> updateWebSocket(serverId, payload)
            is WebSocketClosed -> updateWebSocket(serverId, payload)
            is WebSocketFailed -> updateWebSocket(serverId, payload)
            is WebSocketCloseRequested -> updateWebSocket(serverId, payload)
            is WebSocketCancelled -> updateWebSocket(serverId, payload)
            else -> Unit
        }
    }

    suspend fun clearCompletedEntries() {
        mutex.withLock {
            val retainedSockets = webSocketStates.filterValues { session ->
                !isComplete(session)
            }
            webSocketStates.clear()
            webSocketStates.putAll(retainedSockets)
            webSocketOrder.retainAll(retainedSockets.keys)
            broadcastWebSocketsLocked()
        }
    }

    suspend fun removeServer(serverId: SnapOLinkServerId) {
        mutex.withLock {
            webSocketOrder.removeAll { it.serverId == serverId }
            val toRemove = webSocketStates.keys.filter { it.serverId == serverId }
            for (key in toRemove) webSocketStates.remove(key)
            broadcastWebSocketsLocked()
        }
    }

    private fun isComplete(session: NetworkInspectorWebSocket): Boolean {
        if (session.failed != null) return true
        if (session.cancelled != null) return true
        if (session.closed != null) return true
        if (session.closing != null) return true
        return false
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketWillOpen) {
        val now = Instant.now()
        val id = NetworkInspectorWebSocketId(serverId = serverId, socketId = record.id)

        mutex.withLock {
            val existing = webSocketStates[id]
            val updated = if (existing == null) {
                NetworkInspectorWebSocket(
                    serverId = serverId,
                    socketId = record.id,
                    willOpen = record,
                    opened = null,
                    closing = null,
                    closed = null,
                    failed = null,
                    closeRequested = null,
                    cancelled = null,
                    messages = emptyList(),
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { webSocketOrder.add(id) }
            } else {
                existing.copy(
                    willOpen = record,
                    failed = null,
                    lastUpdatedAt = now,
                )
            }

            webSocketStates[id] = updated
            broadcastWebSocketsLocked()
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketOpened) {
        val now = Instant.now()
        val id = NetworkInspectorWebSocketId(serverId = serverId, socketId = record.id)

        mutex.withLock {
            val existing = webSocketStates[id]
            val updated = if (existing == null) {
                NetworkInspectorWebSocket(
                    serverId = serverId,
                    socketId = record.id,
                    willOpen = null,
                    opened = record,
                    closing = null,
                    closed = null,
                    failed = null,
                    closeRequested = null,
                    cancelled = null,
                    messages = emptyList(),
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { webSocketOrder.add(id) }
            } else {
                existing.copy(
                    opened = record,
                    failed = null,
                    lastUpdatedAt = now,
                )
            }

            webSocketStates[id] = updated
            broadcastWebSocketsLocked()
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketMessageSent) {
        val now = Instant.now()
        val id = NetworkInspectorWebSocketId(serverId = serverId, socketId = record.id)

        mutex.withLock {
            val existing = webSocketStates[id]
                ?: NetworkInspectorWebSocket(
                    serverId = serverId,
                    socketId = record.id,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { webSocketOrder.add(id) }

            val messages = (existing.messages + WebSocketMessage.fromSent(record))
                .sortedWith(compareBy<WebSocketMessage> { it.tWallMs }.thenBy { it.tMonoNs })

            webSocketStates[id] = existing.copy(
                messages = messages,
                failed = null,
                lastUpdatedAt = now,
            )
            broadcastWebSocketsLocked()
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketMessageReceived) {
        val now = Instant.now()
        val id = NetworkInspectorWebSocketId(serverId = serverId, socketId = record.id)

        mutex.withLock {
            val existing = webSocketStates[id]
                ?: NetworkInspectorWebSocket(
                    serverId = serverId,
                    socketId = record.id,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { webSocketOrder.add(id) }

            val messages = (existing.messages + WebSocketMessage.fromReceived(record))
                .sortedWith(compareBy<WebSocketMessage> { it.tWallMs }.thenBy { it.tMonoNs })

            webSocketStates[id] = existing.copy(
                messages = messages,
                failed = null,
                lastUpdatedAt = now,
            )
            broadcastWebSocketsLocked()
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketClosing) {
        updateWebSocketTerminal(serverId, record.id) { existing, now ->
            existing.copy(closing = record, lastUpdatedAt = now)
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketClosed) {
        updateWebSocketTerminal(serverId, record.id) { existing, now ->
            existing.copy(closed = record, lastUpdatedAt = now)
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketFailed) {
        updateWebSocketTerminal(serverId, record.id) { existing, now ->
            existing.copy(failed = record, lastUpdatedAt = now)
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketCloseRequested) {
        updateWebSocketTerminal(serverId, record.id) { existing, now ->
            existing.copy(closeRequested = record, lastUpdatedAt = now)
        }
    }

    private suspend fun updateWebSocket(serverId: SnapOLinkServerId, record: WebSocketCancelled) {
        updateWebSocketTerminal(serverId, record.id) { existing, now ->
            existing.copy(cancelled = record, lastUpdatedAt = now)
        }
    }

    private suspend fun updateWebSocketTerminal(
        serverId: SnapOLinkServerId,
        socketId: String,
        transform: (NetworkInspectorWebSocket, Instant) -> NetworkInspectorWebSocket,
    ) {
        val now = Instant.now()
        val id = NetworkInspectorWebSocketId(serverId = serverId, socketId = socketId)

        mutex.withLock {
            val existing = webSocketStates[id]
                ?: NetworkInspectorWebSocket(
                    serverId = serverId,
                    socketId = socketId,
                    firstSeenAt = now,
                    lastUpdatedAt = now,
                ).also { webSocketOrder.add(id) }

            webSocketStates[id] = transform(existing, now)
            broadcastWebSocketsLocked()
        }
    }

    private fun broadcastWebSocketsLocked() {
        _webSockets.value = webSocketOrder.mapNotNull { webSocketStates[it] }
    }
}

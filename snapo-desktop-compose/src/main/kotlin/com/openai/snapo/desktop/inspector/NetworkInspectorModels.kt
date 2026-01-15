package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.protocol.AppIcon
import com.openai.snapo.desktop.protocol.Header
import com.openai.snapo.desktop.protocol.Hello
import com.openai.snapo.desktop.protocol.RequestFailed
import com.openai.snapo.desktop.protocol.RequestWillBeSent
import com.openai.snapo.desktop.protocol.ResponseReceived
import com.openai.snapo.desktop.protocol.ResponseStreamClosed
import com.openai.snapo.desktop.protocol.ResponseStreamEvent
import com.openai.snapo.desktop.protocol.WebSocketCancelled
import com.openai.snapo.desktop.protocol.WebSocketCloseRequested
import com.openai.snapo.desktop.protocol.WebSocketClosed
import com.openai.snapo.desktop.protocol.WebSocketClosing
import com.openai.snapo.desktop.protocol.WebSocketFailed
import com.openai.snapo.desktop.protocol.WebSocketMessageReceived
import com.openai.snapo.desktop.protocol.WebSocketMessageSent
import com.openai.snapo.desktop.protocol.WebSocketOpened
import com.openai.snapo.desktop.protocol.WebSocketWillOpen
import java.time.Instant
import java.util.UUID

data class SnapOLinkServerId(
    val deviceId: String,
    val socketName: String,
)

data class SnapOLinkServer(
    val deviceId: String,
    val socketName: String,
    val localPort: Int,
    val hello: Hello? = null,
    val schemaVersion: Int? = null,
    val isSchemaNewerThanSupported: Boolean = false,
    val lastEventAt: Instant? = null,
    val deviceDisplayTitle: String = deviceId,
    val isConnected: Boolean = true,
    val appIcon: AppIcon? = null,
    val packageNameHint: String? = null,
    val features: Set<String> = emptySet(),
) {
    val id: SnapOLinkServerId get() = SnapOLinkServerId(deviceId = deviceId, socketName = socketName)
    val hasHello: Boolean get() = hello != null
}

data class SnapOLinkEvent(
    val id: UUID = UUID.randomUUID(),
    val serverId: SnapOLinkServerId,
    val receivedAt: Instant,
    val recordType: String,
)

data class NetworkInspectorRequestId(
    val serverId: SnapOLinkServerId,
    val requestId: String,
)

data class NetworkInspectorRequest(
    val serverId: SnapOLinkServerId,
    val requestId: String,
    val request: RequestWillBeSent? = null,
    val response: ResponseReceived? = null,
    val failure: RequestFailed? = null,
    val streamEvents: List<ResponseStreamEvent> = emptyList(),
    val streamClosed: ResponseStreamClosed? = null,
    val firstSeenAt: Instant,
    val lastUpdatedAt: Instant,
) {
    val id: NetworkInspectorRequestId get() = NetworkInspectorRequestId(serverId = serverId, requestId = requestId)
}

val NetworkInspectorRequest.isLikelyStreamingResponse: Boolean
    get() {
        if (streamEvents.isNotEmpty()) return true
        if (hasEventStreamHeader(response?.headers)) return true
        if (hasEventStreamHeader(request?.headers)) return true
        return false
    }

private fun hasEventStreamHeader(headers: List<Header>?): Boolean {
    if (headers.isNullOrEmpty()) return false
    return headers.any { header ->
        val name = header.name.lowercase()
        val value = header.value.lowercase()
        (name == "content-type" || name == "accept") && value.contains("text/event-stream")
    }
}

data class NetworkInspectorWebSocketId(
    val serverId: SnapOLinkServerId,
    val socketId: String,
)

data class NetworkInspectorWebSocket(
    val serverId: SnapOLinkServerId,
    val socketId: String,
    val willOpen: WebSocketWillOpen? = null,
    val opened: WebSocketOpened? = null,
    val closing: WebSocketClosing? = null,
    val closed: WebSocketClosed? = null,
    val failed: WebSocketFailed? = null,
    val closeRequested: WebSocketCloseRequested? = null,
    val cancelled: WebSocketCancelled? = null,
    val messages: List<WebSocketMessage> = emptyList(),
    val firstSeenAt: Instant,
    val lastUpdatedAt: Instant,
) {
    val id: NetworkInspectorWebSocketId get() = NetworkInspectorWebSocketId(serverId = serverId, socketId = socketId)
}

data class WebSocketMessage(
    val id: UUID = UUID.randomUUID(),
    val socketId: String,
    val direction: Direction,
    val opcode: String,
    val preview: String?,
    val payloadSize: Long?,
    val enqueued: Boolean?,
    val tWallMs: Long,
    val tMonoNs: Long,
    val timestamp: Instant,
) {
    enum class Direction { Outgoing, Incoming }

    companion object {
        fun fromSent(record: WebSocketMessageSent): WebSocketMessage =
            WebSocketMessage(
                socketId = record.id,
                direction = Direction.Outgoing,
                opcode = record.opcode,
                preview = record.preview,
                payloadSize = record.payloadSize,
                enqueued = record.enqueued,
                tWallMs = record.tWallMs,
                tMonoNs = record.tMonoNs,
                timestamp = Instant.ofEpochMilli(record.tWallMs),
            )

        fun fromReceived(record: WebSocketMessageReceived): WebSocketMessage =
            WebSocketMessage(
                socketId = record.id,
                direction = Direction.Incoming,
                opcode = record.opcode,
                preview = record.preview,
                payloadSize = record.payloadSize,
                enqueued = null,
                tWallMs = record.tWallMs,
                tMonoNs = record.tMonoNs,
                timestamp = Instant.ofEpochMilli(record.tWallMs),
            )
    }
}

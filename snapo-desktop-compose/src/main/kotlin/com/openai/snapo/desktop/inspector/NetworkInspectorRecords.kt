package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.protocol.CdpEventSourceMessageReceivedParams
import com.openai.snapo.desktop.protocol.CdpLoadingFailedParams
import com.openai.snapo.desktop.protocol.CdpLoadingFinishedParams
import com.openai.snapo.desktop.protocol.CdpRequestWillBeSentParams
import com.openai.snapo.desktop.protocol.CdpResponseReceivedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketClosedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketCreatedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameErrorParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameReceivedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameSentParams
import com.openai.snapo.desktop.protocol.CdpWebSocketHandshakeResponseReceivedParams

data class Header(
    val name: String,
    val value: String,
)

sealed interface NetworkEventRecord

sealed interface TimedRecord {
    val tWallMs: Long
    val tMonoNs: Long
}

sealed interface PerRequestRecord : NetworkEventRecord, TimedRecord {
    val id: String
}

data class RequestWillBeSent(
    val params: CdpRequestWillBeSentParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val body: String? = null,
) : PerRequestRecord {
    override val id: String get() = params.requestId
    val method: String get() = params.request.method
    val url: String get() = params.request.url
    val headers: List<Header> get() = params.request.headers.toHeaderList()
    val bodyPreview: String? get() = null
    val bodyEncoding: String? get() = params.request.postDataEncoding
    val bodyTruncatedBytes: Long? get() = null
    val bodySize: Long?
        get() = params.request.postDataLength ?: if (params.request.hasPostData) -1L else 0L
}

data class ResponseReceived(
    val params: CdpResponseReceivedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val body: String? = null,
    val bodyBase64Encoded: Boolean = false,
) : PerRequestRecord {
    override val id: String get() = params.requestId
    val code: Int get() = params.response.status
    val headers: List<Header> get() = params.response.headers.toHeaderList()
    val bodyPreview: String? get() = null
    val bodyTruncatedBytes: Long? get() = null
    val bodySize: Long? get() = params.response.encodedDataLength?.toLong()
    val bodyEncoding: String? get() = params.response.bodyEncoding
    val mimeType: String? get() = params.response.mimeType
}

data class RequestFailed(
    val params: CdpLoadingFailedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerRequestRecord {
    override val id: String get() = params.requestId
    val errorKind: String get() = params.type ?: "NetworkError"
    val message: String? get() = params.errorText
}

data class ResponseFinished(
    val params: CdpLoadingFinishedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerRequestRecord {
    override val id: String get() = params.requestId
    val bodySize: Long? get() = params.encodedDataLength?.toLong()
}

data class ResponseStreamEvent(
    val params: CdpEventSourceMessageReceivedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val sequence: Long,
    val raw: String,
) : PerRequestRecord {
    override val id: String get() = params.requestId
}

data class ResponseStreamClosed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val reason: String,
    val message: String? = null,
    val totalEvents: Long,
    val totalBytes: Long,
) : PerRequestRecord

sealed interface PerWebSocketRecord : NetworkEventRecord, TimedRecord {
    val id: String
}

data class WebSocketWillOpen(
    val params: CdpWebSocketCreatedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val url: String get() = params.url
    val headers: List<Header> get() = params.headers.toHeaderList()
}

data class WebSocketOpened(
    val params: CdpWebSocketHandshakeResponseReceivedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val code: Int get() = params.response.status
    val headers: List<Header> get() = params.response.headers.toHeaderList()
}

data class WebSocketMessageSent(
    val params: CdpWebSocketFrameSentParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val opcode: String get() = params.response.opcode.toWebSocketOpcodeLabel()
    val preview: String? get() = params.response.payloadData.ifBlank { null }
    val payloadSize: Long? get() = params.response.payloadSize
    val enqueued: Boolean get() = params.response.enqueued ?: true
}

data class WebSocketMessageReceived(
    val params: CdpWebSocketFrameReceivedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val opcode: String get() = params.response.opcode.toWebSocketOpcodeLabel()
    val preview: String? get() = params.response.payloadData.ifBlank { null }
    val payloadSize: Long? get() = params.response.payloadSize
}

data class WebSocketClosing(
    val params: CdpWebSocketFrameReceivedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val code: Int get() = params.response.closeCode ?: 1000
    val reason: String? get() = params.response.closeReason
}

data class WebSocketClosed(
    val params: CdpWebSocketClosedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val code: Int get() = params.code ?: 1000
    val reason: String? get() = params.reason
}

data class WebSocketFailed(
    val params: CdpWebSocketFrameErrorParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val errorKind: String get() = "WebSocketError"
    val message: String? get() = params.errorMessage
}

data class WebSocketCloseRequested(
    val params: CdpWebSocketFrameSentParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
    val code: Int get() = params.response.closeCode ?: 1000
    val reason: String? get() = params.response.closeReason
    val initiated: String get() = params.response.closeInitiated ?: "client"
    val accepted: Boolean get() = params.response.closeAccepted ?: true
}

data class WebSocketCancelled(
    val params: CdpWebSocketClosedParams,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord {
    override val id: String get() = params.requestId
}

private fun Map<String, String>.toHeaderList(): List<Header> {
    if (isEmpty()) return emptyList()
    return entries.flatMap { (name, rawValue) ->
        rawValue.split("\n").map { value -> Header(name = name, value = value) }
    }
}

private fun Int.toWebSocketOpcodeLabel(): String {
    return when (this) {
        1 -> "text"
        2 -> "binary"
        8 -> "close"
        9 -> "ping"
        10 -> "pong"
        else -> "text"
    }
}

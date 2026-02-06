package com.openai.snapo.desktop.protocol

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class CdpMessage(
    val id: Int? = null,
    val method: String? = null,
    val params: JsonElement? = null,
    val result: JsonElement? = null,
    val error: CdpError? = null,
)

@Serializable
data class CdpError(
    val code: Int,
    val message: String,
    val data: JsonElement? = null,
)

object CdpNetworkMethod {
    const val RequestWillBeSent: String = "Network.requestWillBeSent"
    const val ResponseReceived: String = "Network.responseReceived"
    const val LoadingFinished: String = "Network.loadingFinished"
    const val LoadingFailed: String = "Network.loadingFailed"
    const val EventSourceMessageReceived: String = "Network.eventSourceMessageReceived"

    const val WebSocketCreated: String = "Network.webSocketCreated"
    const val WebSocketHandshakeResponseReceived: String = "Network.webSocketHandshakeResponseReceived"
    const val WebSocketFrameSent: String = "Network.webSocketFrameSent"
    const val WebSocketFrameReceived: String = "Network.webSocketFrameReceived"
    const val WebSocketClosed: String = "Network.webSocketClosed"
    const val WebSocketFrameError: String = "Network.webSocketFrameError"

    const val GetRequestPostData: String = "Network.getRequestPostData"
    const val GetResponseBody: String = "Network.getResponseBody"
}

@Serializable
data class CdpRequestWillBeSentParams(
    val requestId: String,
    val wallTime: Double? = null,
    val timestamp: Double? = null,
    val request: CdpRequestData,
)

@Serializable
data class CdpRequestData(
    val url: String,
    val method: String,
    val headers: Map<String, String> = emptyMap(),
    val hasPostData: Boolean = false,
    val postDataLength: Long? = null,
    val postDataEncoding: String? = null,
)

@Serializable
data class CdpResponseReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val type: String? = null,
    val response: CdpResponseData,
)

@Serializable
data class CdpResponseData(
    val url: String? = null,
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val mimeType: String? = null,
    val encodedDataLength: Double? = null,
    val bodyEncoding: String? = null,
)

@Serializable
data class CdpLoadingFinishedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val encodedDataLength: Double? = null,
)

@Serializable
data class CdpLoadingFailedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val type: String? = null,
    val errorText: String? = null,
)

@Serializable
data class CdpEventSourceMessageReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val eventName: String? = null,
    val eventId: String? = null,
    val data: String? = null,
)

@Serializable
data class CdpWebSocketCreatedParams(
    val requestId: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val wallTime: Double? = null,
    val timestamp: Double? = null,
)

@Serializable
data class CdpWebSocketHandshakeResponseReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val response: CdpWebSocketHandshakeResponse,
)

@Serializable
data class CdpWebSocketHandshakeResponse(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
)

@Serializable
data class CdpWebSocketFrameSentParams(
    val requestId: String,
    val timestamp: Double? = null,
    val response: CdpWebSocketFrame,
)

@Serializable
data class CdpWebSocketFrameReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val response: CdpWebSocketFrame,
)

@Serializable
data class CdpWebSocketFrame(
    val opcode: Int,
    val mask: Boolean,
    val payloadData: String,
    val payloadSize: Long? = null,
    val enqueued: Boolean? = null,
    val closeCode: Int? = null,
    val closeReason: String? = null,
    val closeInitiated: String? = null,
    val closeAccepted: Boolean? = null,
)

@Serializable
data class CdpWebSocketClosedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val code: Int? = null,
    val reason: String? = null,
)

@Serializable
data class CdpWebSocketFrameErrorParams(
    val requestId: String,
    val timestamp: Double? = null,
    val errorMessage: String? = null,
)

@Serializable
data class CdpGetRequestPostDataParams(
    val requestId: String,
)

@Serializable
data class CdpGetRequestPostDataResult(
    val postData: String,
)

@Serializable
data class CdpGetResponseBodyParams(
    val requestId: String,
)

@Serializable
data class CdpGetResponseBodyResult(
    val body: String,
    val base64Encoded: Boolean,
)

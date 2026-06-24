package com.openai.snapo.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
internal data class CdpMessage(
    val id: Int? = null,
    val method: String? = null,
    val params: JsonElement? = null,
    val result: JsonElement? = null,
    val error: CdpError? = null,
)

@Serializable
internal data class CdpError(
    val code: Int,
    val message: String,
    val data: JsonElement? = null,
)

internal object CdpNetworkMethod {
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
internal data class CdpRequestWillBeSentParams(
    val requestId: String,
    val wallTime: Double? = null,
    val timestamp: Double? = null,
    val request: CdpRequestData,
)

@Serializable
internal data class CdpRequestData(
    val url: String,
    val method: String,
    val headers: Map<String, String> = emptyMap(),
    val hasPostData: Boolean = false,
    val postDataLength: Long? = null,
    val postDataEncoding: String? = null,
)

@Serializable
internal data class CdpResponseReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val type: String? = null,
    val response: CdpResponseData,
)

@Serializable
internal data class CdpResponseData(
    val url: String? = null,
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val mimeType: String? = null,
    val encodedDataLength: Double? = null,
    val bodyEncoding: String? = null,
)

@Serializable
internal data class CdpLoadingFinishedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val encodedDataLength: Double? = null,
)

@Serializable
internal data class CdpLoadingFailedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val type: String? = null,
    val errorText: String? = null,
)

@Serializable
internal data class CdpEventSourceMessageReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val eventName: String? = null,
    val eventId: String? = null,
    val data: String? = null,
)

@Serializable
internal data class CdpWebSocketCreatedParams(
    val requestId: String,
    val url: String,
    val headers: Map<String, String> = emptyMap(),
    val wallTime: Double? = null,
    val timestamp: Double? = null,
)

@Serializable
internal data class CdpWebSocketHandshakeResponseReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val response: CdpWebSocketHandshakeResponse,
)

@Serializable
internal data class CdpWebSocketHandshakeResponse(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
)

@Serializable
internal data class CdpWebSocketFrameSentParams(
    val requestId: String,
    val timestamp: Double? = null,
    val response: CdpWebSocketFrame,
)

@Serializable
internal data class CdpWebSocketFrameReceivedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val response: CdpWebSocketFrame,
)

@Serializable
internal data class CdpWebSocketFrame(
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
internal data class CdpWebSocketClosedParams(
    val requestId: String,
    val timestamp: Double? = null,
    val code: Int? = null,
    val reason: String? = null,
)

@Serializable
internal data class CdpWebSocketFrameErrorParams(
    val requestId: String,
    val timestamp: Double? = null,
    val errorMessage: String? = null,
)

@Serializable
internal data class CdpGetRequestPostDataParams(
    val requestId: String,
)

@Serializable
internal data class CdpGetRequestPostDataResult(
    val postData: String,
)

@Serializable
internal data class CdpGetResponseBodyParams(
    val requestId: String,
)

@Serializable
internal data class CdpGetResponseBodyResult(
    val body: String,
    val base64Encoded: Boolean,
)

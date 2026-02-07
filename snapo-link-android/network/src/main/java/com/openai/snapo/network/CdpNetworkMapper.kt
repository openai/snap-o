package com.openai.snapo.network

import com.openai.snapo.link.core.CdpEventSourceMessageReceivedParams
import com.openai.snapo.link.core.CdpLoadingFailedParams
import com.openai.snapo.link.core.CdpLoadingFinishedParams
import com.openai.snapo.link.core.CdpMessage
import com.openai.snapo.link.core.CdpNetworkMethod
import com.openai.snapo.link.core.CdpRequestData
import com.openai.snapo.link.core.CdpRequestWillBeSentParams
import com.openai.snapo.link.core.CdpResponseData
import com.openai.snapo.link.core.CdpResponseReceivedParams
import com.openai.snapo.link.core.CdpWebSocketClosedParams
import com.openai.snapo.link.core.CdpWebSocketCreatedParams
import com.openai.snapo.link.core.CdpWebSocketFrame
import com.openai.snapo.link.core.CdpWebSocketFrameErrorParams
import com.openai.snapo.link.core.CdpWebSocketFrameReceivedParams
import com.openai.snapo.link.core.CdpWebSocketFrameSentParams
import com.openai.snapo.link.core.CdpWebSocketHandshakeResponse
import com.openai.snapo.link.core.CdpWebSocketHandshakeResponseReceivedParams
import com.openai.snapo.link.core.Ndjson
import com.openai.snapo.network.record.Header
import com.openai.snapo.network.record.NetworkEventRecord
import com.openai.snapo.network.record.RequestFailed
import com.openai.snapo.network.record.RequestWillBeSent
import com.openai.snapo.network.record.ResponseReceived
import com.openai.snapo.network.record.ResponseStreamClosed
import com.openai.snapo.network.record.ResponseStreamEvent
import com.openai.snapo.network.record.WebSocketCancelled
import com.openai.snapo.network.record.WebSocketCloseRequested
import com.openai.snapo.network.record.WebSocketClosed
import com.openai.snapo.network.record.WebSocketClosing
import com.openai.snapo.network.record.WebSocketFailed
import com.openai.snapo.network.record.WebSocketMessageReceived
import com.openai.snapo.network.record.WebSocketMessageSent
import com.openai.snapo.network.record.WebSocketOpened
import com.openai.snapo.network.record.WebSocketWillOpen

@Suppress("CyclomaticComplexMethod")
internal fun NetworkEventRecord.toCdpMessage(requestUrl: String?): CdpMessage {
    return when (this) {
        is RequestWillBeSent -> toCdpRequestWillBeSent()
        is ResponseReceived -> toCdpResponseReceived(requestUrl)
        is RequestFailed -> toCdpLoadingFailed()
        is ResponseStreamEvent -> toCdpEventSourceMessageReceived()
        is ResponseStreamClosed -> toCdpStreamClosed()
        is WebSocketWillOpen -> toCdpWebSocketCreated()
        is WebSocketOpened -> toCdpWebSocketOpened()
        is WebSocketMessageSent -> toCdpWebSocketMessageSent()
        is WebSocketMessageReceived -> toCdpWebSocketMessageReceived()
        is WebSocketClosing -> toCdpWebSocketClosing()
        is WebSocketClosed -> toCdpWebSocketClosed()
        is WebSocketFailed -> toCdpWebSocketFailed()
        is WebSocketCloseRequested -> toCdpWebSocketCloseRequested()
        is WebSocketCancelled -> toCdpWebSocketCancelled()
    }
}

private fun RequestWillBeSent.toCdpRequestWillBeSent(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.RequestWillBeSent,
        params = Ndjson.encodeToJsonElement(
            CdpRequestWillBeSentParams.serializer(),
            CdpRequestWillBeSentParams(
                requestId = id,
                wallTime = tWallMs.toEpochSeconds(),
                timestamp = tMonoNs.toMonotonicSeconds(),
                request = CdpRequestData(
                    url = url,
                    method = method,
                    headers = headers.toCdpHeaderMap(),
                    hasPostData = (bodySize ?: 0L) > 0L || !body.isNullOrEmpty(),
                    postDataLength = bodySize,
                    postDataEncoding = bodyEncoding,
                ),
            ),
        ),
    )
}

private fun ResponseReceived.toCdpResponseReceived(requestUrl: String?): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.ResponseReceived,
        params = Ndjson.encodeToJsonElement(
            CdpResponseReceivedParams.serializer(),
            CdpResponseReceivedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                type = if (headers.isEventStream()) "EventSource" else "XHR",
                response = CdpResponseData(
                    url = requestUrl,
                    status = code,
                    headers = headers.toCdpHeaderMap(),
                    mimeType = headers.contentType(),
                    encodedDataLength = bodySize?.toDouble(),
                    bodyEncoding = inferBodyEncoding(),
                ),
            ),
        ),
    )
}

private fun RequestFailed.toCdpLoadingFailed(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.LoadingFailed,
        params = Ndjson.encodeToJsonElement(
            CdpLoadingFailedParams.serializer(),
            CdpLoadingFailedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                type = "XHR",
                errorText = message ?: errorKind,
            ),
        ),
    )
}

private fun ResponseStreamEvent.toCdpEventSourceMessageReceived(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.EventSourceMessageReceived,
        params = Ndjson.encodeToJsonElement(
            CdpEventSourceMessageReceivedParams.serializer(),
            CdpEventSourceMessageReceivedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                eventName = "message",
                eventId = sequence.toString(),
                data = raw,
            ),
        ),
    )
}

private fun ResponseStreamClosed.toCdpStreamClosed(): CdpMessage {
    return if (reason == "completed") {
        CdpMessage(
            method = CdpNetworkMethod.LoadingFinished,
            params = Ndjson.encodeToJsonElement(
                CdpLoadingFinishedParams.serializer(),
                CdpLoadingFinishedParams(
                    requestId = id,
                    timestamp = tMonoNs.toMonotonicSeconds(),
                    encodedDataLength = totalBytes.toDouble(),
                ),
            ),
        )
    } else {
        CdpMessage(
            method = CdpNetworkMethod.LoadingFailed,
            params = Ndjson.encodeToJsonElement(
                CdpLoadingFailedParams.serializer(),
                CdpLoadingFailedParams(
                    requestId = id,
                    timestamp = tMonoNs.toMonotonicSeconds(),
                    type = "EventSource",
                    errorText = message ?: reason,
                ),
            ),
        )
    }
}

private fun WebSocketWillOpen.toCdpWebSocketCreated(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketCreated,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketCreatedParams.serializer(),
            CdpWebSocketCreatedParams(
                requestId = id,
                url = url,
                headers = headers.toCdpHeaderMap(),
                wallTime = tWallMs.toEpochSeconds(),
                timestamp = tMonoNs.toMonotonicSeconds(),
            ),
        ),
    )
}

private fun WebSocketOpened.toCdpWebSocketOpened(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketHandshakeResponseReceived,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketHandshakeResponseReceivedParams.serializer(),
            CdpWebSocketHandshakeResponseReceivedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                response = CdpWebSocketHandshakeResponse(
                    status = code,
                    headers = headers.toCdpHeaderMap(),
                ),
            ),
        ),
    )
}

private fun WebSocketMessageSent.toCdpWebSocketMessageSent(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketFrameSent,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketFrameSentParams.serializer(),
            CdpWebSocketFrameSentParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                response = CdpWebSocketFrame(
                    opcode = opcode.toWebSocketOpcode(),
                    mask = true,
                    payloadData = preview.orEmpty(),
                    payloadSize = payloadSize,
                    enqueued = enqueued,
                ),
            ),
        ),
    )
}

private fun WebSocketMessageReceived.toCdpWebSocketMessageReceived(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketFrameReceived,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketFrameReceivedParams.serializer(),
            CdpWebSocketFrameReceivedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                response = CdpWebSocketFrame(
                    opcode = opcode.toWebSocketOpcode(),
                    mask = false,
                    payloadData = preview.orEmpty(),
                    payloadSize = payloadSize,
                ),
            ),
        ),
    )
}

private fun WebSocketClosing.toCdpWebSocketClosing(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketFrameReceived,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketFrameReceivedParams.serializer(),
            CdpWebSocketFrameReceivedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                response = CdpWebSocketFrame(
                    opcode = 8,
                    mask = false,
                    payloadData = reason.orEmpty(),
                    closeCode = code,
                    closeReason = reason,
                ),
            ),
        ),
    )
}

private fun WebSocketCloseRequested.toCdpWebSocketCloseRequested(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketFrameSent,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketFrameSentParams.serializer(),
            CdpWebSocketFrameSentParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                response = CdpWebSocketFrame(
                    opcode = 8,
                    mask = true,
                    payloadData = reason.orEmpty(),
                    closeCode = code,
                    closeReason = reason,
                    closeInitiated = initiated,
                    closeAccepted = accepted,
                ),
            ),
        ),
    )
}

private fun WebSocketClosed.toCdpWebSocketClosed(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketClosed,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketClosedParams.serializer(),
            CdpWebSocketClosedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                code = code,
                reason = reason,
            ),
        ),
    )
}

private fun WebSocketFailed.toCdpWebSocketFailed(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketFrameError,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketFrameErrorParams.serializer(),
            CdpWebSocketFrameErrorParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                errorMessage = message ?: errorKind,
            ),
        ),
    )
}

private fun WebSocketCancelled.toCdpWebSocketCancelled(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.WebSocketClosed,
        params = Ndjson.encodeToJsonElement(
            CdpWebSocketClosedParams.serializer(),
            CdpWebSocketClosedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                reason = "cancelled",
            ),
        ),
    )
}

private fun ResponseReceived.inferBodyEncoding(): String? {
    if ((bodySize ?: 0L) <= 0L && body.isNullOrEmpty()) return null
    return if (headers.isTextLikeContentType()) null else "base64"
}

private fun List<Header>.toCdpHeaderMap(): Map<String, String> {
    if (isEmpty()) return emptyMap()
    val grouped = LinkedHashMap<String, MutableList<String>>()
    for (header in this) {
        grouped.getOrPut(header.name) { mutableListOf() }.add(header.value)
    }
    return grouped.mapValues { (_, values) -> values.joinToString(separator = "\n") }
}

private fun List<Header>.contentType(): String? {
    return firstOrNull { it.name.equals("Content-Type", ignoreCase = true) }
        ?.value
        ?.substringBefore(';')
        ?.trim()
        ?.ifBlank { null }
}

private fun List<Header>.isEventStream(): Boolean {
    val contentType = contentType() ?: return false
    return contentType.equals("text/event-stream", ignoreCase = true)
}

private fun List<Header>.isTextLikeContentType(): Boolean {
    val contentType = contentType()?.lowercase() ?: return false
    if (contentType.startsWith("text/")) return true
    return listOf(
        "json",
        "xml",
        "html",
        "javascript",
        "form",
        "graphql",
        "plain",
        "csv",
        "yaml",
    ).any(contentType::contains)
}

private fun String.toWebSocketOpcode(): Int {
    return when (lowercase()) {
        "text" -> 1
        "binary" -> 2
        "close" -> 8
        "ping" -> 9
        "pong" -> 10
        else -> 1
    }
}

private fun Long.toEpochSeconds(): Double = toDouble() / 1000.0

private fun Long.toMonotonicSeconds(): Double = toDouble() / 1_000_000_000.0

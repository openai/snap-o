package com.openai.snapo.network

@Suppress("CyclomaticComplexMethod")
internal fun NetworkEventRecord.toCdpMessage(requestUrl: String?): CdpMessage {
    return when (this) {
        is RequestWillBeSent -> toCdpRequestWillBeSent()
        is ResponseReceived -> toCdpResponseReceived(requestUrl)
        is ResponseFinished -> toCdpLoadingFinished()
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
        params = ProtocolJson.encodeToJsonElement(
            CdpRequestWillBeSentParams.serializer(),
            CdpRequestWillBeSentParams(
                requestId = id,
                wallTime = tWallMs.toEpochSeconds(),
                timestamp = tMonoNs.toMonotonicSeconds(),
                request = CdpRequestData(
                    url = url,
                    method = method,
                    headers = headers.toCdpHeaderMap(),
                    hasPostData = hasBody || (bodySize ?: 0L) > 0L || !body.isNullOrEmpty(),
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
        params = ProtocolJson.encodeToJsonElement(
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
                    bodyEncoding = bodyEncoding,
                ),
            ),
        ),
    )
}

private fun RequestFailed.toCdpLoadingFailed(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.LoadingFailed,
        params = ProtocolJson.encodeToJsonElement(
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

private fun ResponseFinished.toCdpLoadingFinished(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.LoadingFinished,
        params = ProtocolJson.encodeToJsonElement(
            CdpLoadingFinishedParams.serializer(),
            CdpLoadingFinishedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                encodedDataLength = bodySize?.toDouble(),
                bodyTruncatedBytes = bodyTruncatedBytes,
            ),
        ),
    )
}

private fun ResponseStreamEvent.toCdpEventSourceMessageReceived(): CdpMessage {
    return CdpMessage(
        method = CdpNetworkMethod.EventSourceMessageReceived,
        params = ProtocolJson.encodeToJsonElement(
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
            params = ProtocolJson.encodeToJsonElement(
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
            params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
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
        params = ProtocolJson.encodeToJsonElement(
            CdpWebSocketClosedParams.serializer(),
            CdpWebSocketClosedParams(
                requestId = id,
                timestamp = tMonoNs.toMonotonicSeconds(),
                reason = "cancelled",
            ),
        ),
    )
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

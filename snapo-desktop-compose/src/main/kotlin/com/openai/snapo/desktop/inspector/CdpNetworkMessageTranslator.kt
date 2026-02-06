package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.protocol.CdpEventSourceMessageReceivedParams
import com.openai.snapo.desktop.protocol.CdpLoadingFailedParams
import com.openai.snapo.desktop.protocol.CdpLoadingFinishedParams
import com.openai.snapo.desktop.protocol.CdpMessage
import com.openai.snapo.desktop.protocol.CdpNetworkMethod
import com.openai.snapo.desktop.protocol.CdpRequestWillBeSentParams
import com.openai.snapo.desktop.protocol.CdpResponseReceivedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketClosedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketCreatedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameErrorParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameReceivedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameSentParams
import com.openai.snapo.desktop.protocol.CdpWebSocketHandshakeResponseReceivedParams
import com.openai.snapo.desktop.protocol.Ndjson
import kotlin.math.roundToLong

internal class CdpNetworkMessageTranslator {
    private var wallOffsetMs: Double? = null
    private val sseRequestIds = mutableSetOf<String>()
    private val sseEventCountByRequestId = mutableMapOf<String, Long>()
    private val sseSequenceByRequestId = mutableMapOf<String, Long>()

    fun toRecord(message: CdpMessage): NetworkEventRecord? {
        val method = message.method ?: return null
        val params = message.params ?: return null

        return when (method) {
            CdpNetworkMethod.RequestWillBeSent -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpRequestWillBeSentParams.serializer(), params)
                }.getOrNull() ?: return null
                toRequestWillBeSent(decoded)
            }

            CdpNetworkMethod.ResponseReceived -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpResponseReceivedParams.serializer(), params)
                }.getOrNull() ?: return null
                toResponseReceived(decoded)
            }

            CdpNetworkMethod.LoadingFinished -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpLoadingFinishedParams.serializer(), params)
                }.getOrNull() ?: return null
                toLoadingFinished(decoded)
            }

            CdpNetworkMethod.LoadingFailed -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpLoadingFailedParams.serializer(), params)
                }.getOrNull() ?: return null
                toLoadingFailed(decoded)
            }

            CdpNetworkMethod.EventSourceMessageReceived -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpEventSourceMessageReceivedParams.serializer(), params)
                }.getOrNull() ?: return null
                toEventSourceMessage(decoded)
            }

            CdpNetworkMethod.WebSocketCreated -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpWebSocketCreatedParams.serializer(), params)
                }.getOrNull() ?: return null
                toWebSocketCreated(decoded)
            }

            CdpNetworkMethod.WebSocketHandshakeResponseReceived -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpWebSocketHandshakeResponseReceivedParams.serializer(), params)
                }.getOrNull() ?: return null
                toWebSocketOpened(decoded)
            }

            CdpNetworkMethod.WebSocketFrameSent -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpWebSocketFrameSentParams.serializer(), params)
                }.getOrNull() ?: return null
                toWebSocketFrameSent(decoded)
            }

            CdpNetworkMethod.WebSocketFrameReceived -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpWebSocketFrameReceivedParams.serializer(), params)
                }.getOrNull() ?: return null
                toWebSocketFrameReceived(decoded)
            }

            CdpNetworkMethod.WebSocketClosed -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpWebSocketClosedParams.serializer(), params)
                }.getOrNull() ?: return null
                toWebSocketClosed(decoded)
            }

            CdpNetworkMethod.WebSocketFrameError -> {
                val decoded = runCatching {
                    Ndjson.decodeFromJsonElement(CdpWebSocketFrameErrorParams.serializer(), params)
                }.getOrNull() ?: return null
                toWebSocketFailed(decoded)
            }

            else -> null
        }
    }

    private fun toRequestWillBeSent(params: CdpRequestWillBeSentParams): RequestWillBeSent {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp, wallTimeSeconds = params.wallTime)
        val monoNs = resolveMonoNs(params.timestamp)
        return RequestWillBeSent(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toResponseReceived(params: CdpResponseReceivedParams): ResponseReceived {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        if (params.type.equals("EventSource", ignoreCase = true)) {
            sseRequestIds.add(params.requestId)
            sseEventCountByRequestId.putIfAbsent(params.requestId, 0L)
            sseSequenceByRequestId.putIfAbsent(params.requestId, 0L)
        }
        return ResponseReceived(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toLoadingFinished(params: CdpLoadingFinishedParams): ResponseStreamClosed? {
        if (!sseRequestIds.contains(params.requestId)) return null
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        val totalEvents = sseEventCountByRequestId.remove(params.requestId) ?: 0L
        sseSequenceByRequestId.remove(params.requestId)
        sseRequestIds.remove(params.requestId)
        return ResponseStreamClosed(
            id = params.requestId,
            tWallMs = wallMs,
            tMonoNs = monoNs,
            reason = "completed",
            message = null,
            totalEvents = totalEvents,
            totalBytes = params.encodedDataLength?.toLong() ?: 0L,
        )
    }

    private fun toLoadingFailed(params: CdpLoadingFailedParams): PerRequestRecord {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        if (sseRequestIds.contains(params.requestId) || params.type.equals("EventSource", ignoreCase = true)) {
            val totalEvents = sseEventCountByRequestId.remove(params.requestId) ?: 0L
            sseSequenceByRequestId.remove(params.requestId)
            sseRequestIds.remove(params.requestId)
            return ResponseStreamClosed(
                id = params.requestId,
                tWallMs = wallMs,
                tMonoNs = monoNs,
                reason = "error",
                message = params.errorText,
                totalEvents = totalEvents,
                totalBytes = 0L,
            )
        }
        return RequestFailed(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toEventSourceMessage(params: CdpEventSourceMessageReceivedParams): ResponseStreamEvent {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        val sequence = params.eventId?.toLongOrNull() ?: nextSseSequence(params.requestId)
        sseRequestIds.add(params.requestId)
        sseEventCountByRequestId[params.requestId] = (sseEventCountByRequestId[params.requestId] ?: 0L) + 1L
        return ResponseStreamEvent(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
            sequence = sequence,
            raw = params.data.orEmpty(),
        )
    }

    private fun toWebSocketCreated(params: CdpWebSocketCreatedParams): WebSocketWillOpen {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp, wallTimeSeconds = params.wallTime)
        val monoNs = resolveMonoNs(params.timestamp)
        return WebSocketWillOpen(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toWebSocketOpened(params: CdpWebSocketHandshakeResponseReceivedParams): WebSocketOpened {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        return WebSocketOpened(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toWebSocketFrameSent(params: CdpWebSocketFrameSentParams): PerWebSocketRecord {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        val frame = params.response
        if (frame.opcode == 8 && frame.closeCode != null) {
            return WebSocketCloseRequested(
                params = params,
                tWallMs = wallMs,
                tMonoNs = monoNs,
            )
        }
        return WebSocketMessageSent(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toWebSocketFrameReceived(params: CdpWebSocketFrameReceivedParams): PerWebSocketRecord {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        val frame = params.response
        if (frame.opcode == 8 && frame.closeCode != null) {
            return WebSocketClosing(
                params = params,
                tWallMs = wallMs,
                tMonoNs = monoNs,
            )
        }
        return WebSocketMessageReceived(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toWebSocketClosed(params: CdpWebSocketClosedParams): PerWebSocketRecord {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        if (params.reason.equals("cancelled", ignoreCase = true) && params.code == null) {
            return WebSocketCancelled(
                params = params,
                tWallMs = wallMs,
                tMonoNs = monoNs,
            )
        }
        return WebSocketClosed(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun toWebSocketFailed(params: CdpWebSocketFrameErrorParams): WebSocketFailed {
        val wallMs = resolveWallMs(timestampSeconds = params.timestamp)
        val monoNs = resolveMonoNs(params.timestamp)
        return WebSocketFailed(
            params = params,
            tWallMs = wallMs,
            tMonoNs = monoNs,
        )
    }

    private fun resolveWallMs(
        timestampSeconds: Double?,
        wallTimeSeconds: Double? = null,
    ): Long {
        if (wallTimeSeconds != null && timestampSeconds != null) {
            wallOffsetMs = (wallTimeSeconds * 1000.0) - (timestampSeconds * 1000.0)
        }
        if (wallTimeSeconds != null) {
            return (wallTimeSeconds * 1000.0).roundToLong()
        }
        if (timestampSeconds != null && wallOffsetMs != null) {
            return ((timestampSeconds * 1000.0) + wallOffsetMs!!).roundToLong()
        }
        return System.currentTimeMillis()
    }

    private fun resolveMonoNs(timestampSeconds: Double?): Long {
        if (timestampSeconds == null) return 0L
        return (timestampSeconds * 1_000_000_000.0).roundToLong().coerceAtLeast(0L)
    }

    private fun nextSseSequence(requestId: String): Long {
        val next = (sseSequenceByRequestId[requestId] ?: 0L) + 1L
        sseSequenceByRequestId[requestId] = next
        return next
    }
}

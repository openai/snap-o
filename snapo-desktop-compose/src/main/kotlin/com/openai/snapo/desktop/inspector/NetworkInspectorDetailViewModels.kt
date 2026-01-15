package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.protocol.Header
import com.openai.snapo.desktop.protocol.RequestWillBeSent
import com.openai.snapo.desktop.protocol.ResponseReceived
import com.openai.snapo.desktop.protocol.ResponseStreamClosed
import com.openai.snapo.desktop.protocol.ResponseStreamEvent
import com.openai.snapo.desktop.protocol.WebSocketCloseRequested
import com.openai.snapo.desktop.protocol.WebSocketClosed
import com.openai.snapo.desktop.protocol.WebSocketClosing
import com.openai.snapo.desktop.protocol.WebSocketOpened
import com.openai.snapo.desktop.util.JsonOrderPreservingFormatter
import kotlinx.serialization.json.Json
import java.net.URI
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Base64
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.round

private val lenientJson = Json { ignoreUnknownKeys = true }
private const val MaxDecodedImageBytes: Int = 8 * 1024 * 1024

data class InspectorTiming(
    val startMillis: Long?,
    val endMillis: Long?,
    val fallbackRange: Pair<Instant, Instant>,
) {
    fun summary(status: NetworkInspectorRequestStatus, now: Instant = Instant.now()): String {
        val startInstant = startMillis?.let { Instant.ofEpochMilli(it) } ?: fallbackRange.first
        val endInstant = endMillis?.let { Instant.ofEpochMilli(it) } ?: fallbackRange.second

        val startString = startInstant.inspectorTimeString()
        val relativeStart = startInstant.inspectorRelativeTimeString(reference = now)
        val startSegment = "Started $relativeStart at $startString"

        return when (status) {
            is NetworkInspectorRequestStatus.Pending -> startSegment
            is NetworkInspectorRequestStatus.Success,
            is NetworkInspectorRequestStatus.Failure,
            -> {
                val durationSeconds = if (startMillis != null && endMillis != null && endMillis > startMillis) {
                    (endMillis - startMillis) / 1000.0
                } else {
                    max(Duration.between(startInstant, endInstant).toMillis(), 0) / 1000.0
                }
                val durationString = formattedDuration(durationSeconds)
                "$durationString total • $startSegment"
            }
        }
    }
}

data class NetworkInspectorRequestUiModel(
    val id: NetworkInspectorRequestId,
    val method: String,
    val url: String,
    val serverId: SnapOLinkServerId,
    val status: NetworkInspectorRequestStatus,
    val timing: InspectorTiming,
    val requestHeaders: List<Header>,
    val responseHeaders: List<Header>,
    val requestBody: BodyPayload?,
    val responseBody: BodyPayload?,
    val streamEvents: List<StreamEvent>,
    val streamClosed: StreamClosed?,
    val isStreamingResponse: Boolean,
) {
    companion object {
        fun from(request: NetworkInspectorRequest): NetworkInspectorRequestUiModel {
            val method = request.request?.method ?: "?"
            val url = request.request?.url ?: "Request ${request.requestId}"
            val status = requestStatus(request)
            val timing = requestTiming(request)

            val requestHeaders = request.request?.headers ?: emptyList()
            val responseHeaders = request.response?.headers ?: emptyList()

            val requestBody = requestBodyPayload(request.request)
            val responseBody = responseBodyPayload(request.response)

            val streamEvents = sortedStreamEvents(request.streamEvents)
            val streamClosed = request.streamClosed?.let { StreamClosed.from(it) }
            val isStreaming = streamEvents.isNotEmpty() || streamClosed != null

            return NetworkInspectorRequestUiModel(
                id = request.id,
                method = method,
                url = url,
                serverId = request.serverId,
                status = status,
                timing = timing,
                requestHeaders = requestHeaders,
                responseHeaders = responseHeaders,
                requestBody = requestBody,
                responseBody = responseBody,
                streamEvents = streamEvents,
                streamClosed = streamClosed,
                isStreamingResponse = isStreaming,
            )
        }
    }

    data class BodyPayload(
        val rawText: String,
        val prettyPrintedText: String?,
        val isLikelyJson: Boolean,
        val isPreview: Boolean,
        val truncatedBytes: Long?,
        val totalBytes: Long?,
        val capturedBytes: Long,
        val encoding: String?,
        val contentType: String?,
        val data: ByteArray?,
    )

    data class StreamEvent(
        val id: Long,
        val sequence: Long,
        val timestamp: Instant,
        val eventName: String?,
        val data: String?,
        val lastEventId: String?,
        val retryMillis: Long?,
        val comment: String?,
        val raw: String,
    ) {
        companion object {
            fun from(record: ResponseStreamEvent): StreamEvent {
                val timestamp = Instant.ofEpochMilli(record.tWallMs)
                val parsed = parseSseRaw(record.raw)
                return StreamEvent(
                    id = record.sequence,
                    sequence = record.sequence,
                    timestamp = timestamp,
                    eventName = parsed.eventName,
                    data = parsed.data,
                    lastEventId = parsed.lastEventId,
                    retryMillis = parsed.retryMillis,
                    comment = parsed.comment,
                    raw = record.raw,
                )
            }
        }
    }

    data class StreamClosed(
        val timestamp: Instant,
        val reason: String,
        val message: String?,
        val totalEvents: Long,
        val totalBytes: Long,
    ) {
        companion object {
            fun from(record: ResponseStreamClosed): StreamClosed =
                StreamClosed(
                    timestamp = Instant.ofEpochMilli(record.tWallMs),
                    reason = record.reason,
                    message = record.message,
                    totalEvents = record.totalEvents,
                    totalBytes = record.totalBytes,
                )
        }
    }
}

data class NetworkInspectorWebSocketUiModel(
    val id: NetworkInspectorWebSocketId,
    val method: String,
    val url: String,
    val serverId: SnapOLinkServerId,
    val status: NetworkInspectorRequestStatus,
    val timing: InspectorTiming,
    val requestHeaders: List<Header>,
    val responseHeaders: List<Header>,
    val opened: WebSocketOpened?,
    val closing: WebSocketClosing?,
    val closed: WebSocketClosed?,
    val closeRequested: WebSocketCloseRequested?,
    val cancelled: Any?,
    val messages: List<Message>,
) {
    data class Message(
        val id: String,
        val direction: WebSocketMessage.Direction,
        val opcode: String,
        val preview: String?,
        val payloadSize: Long?,
        val enqueued: Boolean?,
        val timestamp: Instant,
    ) {
        companion object {
            fun from(message: WebSocketMessage): Message =
                Message(
                    id = message.id.toString(),
                    direction = message.direction,
                    opcode = message.opcode,
                    preview = message.preview,
                    payloadSize = message.payloadSize,
                    enqueued = message.enqueued,
                    timestamp = message.timestamp,
                )
        }
    }

    companion object {
        fun from(session: NetworkInspectorWebSocket): NetworkInspectorWebSocketUiModel {
            val url = session.willOpen?.url ?: "websocket://${session.socketId}"
            val method = resolveWebSocketMethod(url)
            val status = resolveWebSocketStatus(session)
            val timing = resolveWebSocketTiming(session)

            return NetworkInspectorWebSocketUiModel(
                id = session.id,
                method = method,
                url = url,
                serverId = session.serverId,
                status = status,
                timing = timing,
                requestHeaders = session.willOpen?.headers ?: emptyList(),
                responseHeaders = session.opened?.headers ?: emptyList(),
                opened = session.opened,
                closing = session.closing,
                closed = session.closed,
                closeRequested = session.closeRequested,
                cancelled = session.cancelled,
                messages = session.messages.map(Message::from),
            )
        }
    }
}

private fun requestStatus(request: NetworkInspectorRequest): NetworkInspectorRequestStatus =
    when {
        request.failure != null -> NetworkInspectorRequestStatus.Failure(request.failure.message)
        request.response != null -> NetworkInspectorRequestStatus.Success(request.response.code)
        else -> NetworkInspectorRequestStatus.Pending
    }

private fun requestTiming(request: NetworkInspectorRequest): InspectorTiming {
    val startMillis = request.request?.tWallMs
    val endMillis = request.failure?.tWallMs ?: request.response?.tWallMs
    return InspectorTiming(
        startMillis = startMillis,
        endMillis = endMillis,
        fallbackRange = request.firstSeenAt to request.lastUpdatedAt,
    )
}

private fun requestBodyPayload(
    record: RequestWillBeSent?,
): NetworkInspectorRequestUiModel.BodyPayload? {
    val resolved = record ?: return null
    val bodyText = resolved.body ?: resolved.bodyPreview ?: return null
    val contentType = contentTypeFor(resolved.headers)
    val encoding = resolved.bodyEncoding ?: contentType
    val truncated = resolved.bodyTruncatedBytes
    val isPreview = (resolved.body == null) || ((truncated ?: 0) > 0)
    return makeBodyPayload(
        text = bodyText,
        isPreview = isPreview,
        truncatedBytes = truncated,
        totalBytes = resolved.bodySize,
        encoding = encoding,
    )
}

private fun responseBodyPayload(
    record: ResponseReceived?,
): NetworkInspectorRequestUiModel.BodyPayload? {
    val resolved = record ?: return null
    val bodyText = resolved.body ?: resolved.bodyPreview ?: return null
    return makeBodyPayload(
        text = bodyText,
        isPreview = resolved.body == null,
        truncatedBytes = resolved.bodyTruncatedBytes,
        totalBytes = resolved.bodySize,
        encoding = contentTypeFor(resolved.headers),
    )
}

private fun contentTypeFor(headers: List<Header>?): String? {
    return headers
        ?.firstOrNull { it.name.equals("Content-Type", ignoreCase = true) }
        ?.value
}

private fun sortedStreamEvents(
    events: List<ResponseStreamEvent>,
): List<NetworkInspectorRequestUiModel.StreamEvent> {
    if (events.isEmpty()) return emptyList()
    return events
        .sortedWith(compareBy<ResponseStreamEvent> { it.sequence }.thenBy { it.tWallMs })
        .map(NetworkInspectorRequestUiModel.StreamEvent::from)
}

private fun resolveWebSocketMethod(url: String): String {
    val scheme = runCatching { URI(url).scheme }.getOrNull()
    return when (scheme?.lowercase()) {
        "http", "ws" -> "WS"
        "https", "wss" -> "WSS"
        null -> "WS"
        else -> scheme.uppercase()
    }
}

private fun resolveWebSocketStatus(
    session: NetworkInspectorWebSocket,
): NetworkInspectorRequestStatus {
    return when {
        session.failed != null -> NetworkInspectorRequestStatus.Failure(session.failed.message)
        session.cancelled != null -> NetworkInspectorRequestStatus.Failure("Cancelled")
        session.closed != null -> NetworkInspectorRequestStatus.Success(session.closed.code)
        session.closing != null -> NetworkInspectorRequestStatus.Success(session.closing.code)
        session.opened != null -> NetworkInspectorRequestStatus.Success(session.opened.code)
        else -> NetworkInspectorRequestStatus.Pending
    }
}

private fun resolveWebSocketTiming(session: NetworkInspectorWebSocket): InspectorTiming {
    val startMillis = session.willOpen?.tWallMs ?: session.opened?.tWallMs
    val endMillis = session.failed?.tWallMs
        ?: session.closed?.tWallMs
        ?: session.closing?.tWallMs
        ?: session.messages.lastOrNull()?.tWallMs
    return InspectorTiming(
        startMillis = startMillis,
        endMillis = endMillis,
        fallbackRange = session.firstSeenAt to session.lastUpdatedAt,
    )
}

private data class ParsedSse(
    val eventName: String?,
    val data: String?,
    val lastEventId: String?,
    val retryMillis: Long?,
    val comment: String?,
)

private fun parseSseRaw(raw: String): ParsedSse {
    val state = SseParseState()
    for (line in raw.split("\n")) {
        state.consume(line)
    }
    return state.toParsedSse(raw)
}

private class SseParseState {
    private var eventName: String? = null
    private var lastEventId: String? = null
    private var retryMillis: Long? = null
    private val comments = ArrayList<String>()
    private val dataLines = ArrayList<String>()

    fun consume(line: String) {
        if (line.isEmpty()) return
        if (line.startsWith(":")) {
            addComment(line)
            return
        }

        val (field, value) = splitField(line)
        when (field) {
            "event" -> eventName = value
            "data" -> dataLines.add(value)
            "id" -> lastEventId = value
            "retry" -> retryMillis = value.toLongOrNull()
        }
    }

    fun toParsedSse(raw: String): ParsedSse {
        val data = if (dataLines.isEmpty()) {
            if (raw.isEmpty()) "" else null
        } else {
            dataLines.joinToString("\n")
        }

        val commentText = comments.takeIf { it.isNotEmpty() }?.joinToString("\n")

        return ParsedSse(
            eventName = eventName,
            data = data,
            lastEventId = lastEventId,
            retryMillis = retryMillis,
            comment = commentText,
        )
    }

    private fun addComment(line: String) {
        val comment = line.drop(1).trim()
        if (comment.isNotEmpty()) comments.add(comment)
    }

    private fun splitField(line: String): Pair<String, String> {
        val idx = line.indexOf(':')
        val field = if (idx == -1) line else line.substring(0, idx)
        val rawValue = if (idx == -1) "" else line.substring(idx + 1)
        val value = rawValue.removePrefix(" ")
        return field to value
    }
}

private fun makeBodyPayload(
    text: String,
    isPreview: Boolean,
    truncatedBytes: Long?,
    totalBytes: Long?,
    encoding: String?,
): NetworkInspectorRequestUiModel.BodyPayload {
    val capturedBytes = text.toByteArray(Charsets.UTF_8).size.toLong()
    val trimmed = text.trim()

    val encodingLower = encoding?.lowercase()
    val encodingMatchesJson = encodingLower?.contains("json") == true
    val prefixSuggestsJson = trimmed.firstOrNull() == '{' || trimmed.firstOrNull() == '['

    val pretty = prettyPrintedJsonOrNull(text)
    val isLikelyJson = pretty != null || encodingMatchesJson || prefixSuggestsJson

    val normalizedContentType = normalizeContentType(encoding)
    val binaryData = decodeImageDataIfNeeded(trimmed, normalizedContentType)

    return NetworkInspectorRequestUiModel.BodyPayload(
        rawText = text,
        prettyPrintedText = pretty,
        isLikelyJson = isLikelyJson,
        isPreview = isPreview,
        truncatedBytes = truncatedBytes,
        totalBytes = totalBytes,
        capturedBytes = capturedBytes,
        encoding = encoding,
        contentType = normalizedContentType,
        data = binaryData,
    )
}

private fun normalizeContentType(rawValue: String?): String? {
    val raw = rawValue?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val first = raw.split(';', limit = 2).firstOrNull()?.trim()?.lowercase()
    return first?.takeIf { it.isNotEmpty() }
}

private fun decodeImageDataIfNeeded(text: String, contentType: String?): ByteArray? {
    val type = contentType ?: return null
    val supported = listOf("image/png", "image/jpeg", "image/jpg", "image/webp", "image/gif")
    if (supported.none { type.startsWith(it) }) return null

    val trimmed = text.trim()

    val base64Payload = when {
        trimmed.contains("base64,", ignoreCase = true) -> {
            val idx = trimmed.indexOf("base64,", ignoreCase = true)
            trimmed.substring(idx + "base64,".length)
        }
        trimmed.startsWith("data:", ignoreCase = true) && trimmed.contains(',') -> {
            trimmed.substringAfter(',')
        }
        else -> trimmed
    }

    val estimatedBytes = estimateBase64DecodedBytes(base64Payload.length)
    if (estimatedBytes in 1..MaxDecodedImageBytes.toLong()) {
        val decoded = runCatching { Base64.getDecoder().decode(base64Payload) }.getOrNull()
        if (decoded != null && decoded.isNotEmpty() && decoded.size <= MaxDecodedImageBytes) {
            return decoded
        }
    }

    if (trimmed.length > MaxDecodedImageBytes) return null
    val rawBytes = trimmed.toByteArray(Charsets.UTF_8)
    return rawBytes.takeIf { it.isNotEmpty() && it.size <= MaxDecodedImageBytes }
}

private fun estimateBase64DecodedBytes(length: Int): Long {
    if (length <= 0) return 0L
    return (length.toLong() * 3L) / 4L
}

private fun prettyPrintedJsonOrNull(text: String): String? {
    val element = runCatching {
        // Don't use `Ndjson`: bodies are untrusted and may include arbitrary JSON fragments.
        lenientJson.parseToJsonElement(text)
    }.getOrNull() ?: return null

    // Only pretty-print if it was valid JSON.
    return JsonOrderPreservingFormatter.format(text)
        .takeIf { it.isNotBlank() }
        ?: element.toString()
}

private fun formattedDuration(durationSeconds: Double): String {
    return when {
        durationSeconds < 1 -> "%.0f ms".format(durationSeconds * 1000)
        durationSeconds < 10 -> "%.2f s".format(durationSeconds)
        durationSeconds < 60 -> "%.1f s".format(durationSeconds)
        else -> {
            val minutes = (durationSeconds / 60).toInt()
            val seconds = (durationSeconds % 60).toInt()
            "${minutes}m ${seconds}s"
        }
    }
}

private fun Instant.inspectorTimeString(zoneId: ZoneId = ZoneId.systemDefault()): String {
    // "j:mm:ss.SSS" equivalent-ish: keep it compact and include millis.
    val formatter = DateTimeFormatter.ofLocalizedTime(FormatStyle.MEDIUM)
        .withZone(zoneId)
    // MEDIUM may omit millis; fall back to a fixed pattern if so.
    val base = formatter.format(this)
    return if (base.contains('.')) base else DateTimeFormatter.ofPattern("H:mm:ss.SSS").withZone(zoneId).format(this)
}

private fun Instant.inspectorRelativeTimeString(reference: Instant = Instant.now()): String {
    val seconds = round(
        reference.epochSecond - this.epochSecond + (reference.nano - this.nano) / 1_000_000_000.0
    ).toInt()
    if (seconds == 0) return "just now"

    val absoluteSeconds = abs(seconds)
    val isFuture = seconds < 0

    val (value, unit) = when {
        absoluteSeconds < 60 -> absoluteSeconds to "s"
        absoluteSeconds < 3600 -> (absoluteSeconds / 60) to "m"
        absoluteSeconds < 86400 -> (absoluteSeconds / 3600) to "h"
        else -> (absoluteSeconds / 86400) to "d"
    }

    return if (isFuture) "in ${value}$unit" else "${value}$unit ago"
}

package com.openai.snapo.desktop.inspector.export

import com.openai.snapo.desktop.BuildInfo
import com.openai.snapo.desktop.inspector.Header
import com.openai.snapo.desktop.inspector.NetworkInspectorRequest
import com.openai.snapo.desktop.inspector.NetworkInspectorWebSocket
import com.openai.snapo.desktop.inspector.RequestFailed
import com.openai.snapo.desktop.inspector.RequestWillBeSent
import com.openai.snapo.desktop.inspector.ResponseReceived
import com.openai.snapo.desktop.inspector.ResponseStreamEvent
import com.openai.snapo.desktop.inspector.WebSocketMessage
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.URI
import java.net.URLDecoder
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Base64
import kotlin.math.max

object NetworkInspectorHarExporter {
    private val harJson: Json = Json {
        prettyPrint = true
        encodeDefaults = true
        explicitNulls = false
    }

    private val fileNameTimestampFormatter: DateTimeFormatter = DateTimeFormatter
        .ofPattern("yyyyMMdd-HHmmss")
        .withZone(ZoneId.systemDefault())

    private enum class HarHeaderContext {
        Request,
        Response,
    }

    fun exportAsHar(
        requests: List<NetworkInspectorRequest>,
        webSockets: List<NetworkInspectorWebSocket>,
    ) {
        val defaultFileName = defaultFileName(requests.size + webSockets.size)
        val dialogResult = NetworkInspectorHarExportDialog.choose(defaultFileName) ?: return
        val entries = buildHarEntries(
            requests = requests,
            webSockets = webSockets,
        )
        if (entries.isEmpty()) return

        val payload = HarRoot(
            log = HarLog(
                creator = HarCreator(name = "Snap-O", version = BuildInfo.VERSION),
                entries = entries,
            )
        )
        dialogResult.outputFile.writeText(harJson.encodeToString(payload))
    }

    private fun buildHarEntries(
        requests: List<NetworkInspectorRequest>,
        webSockets: List<NetworkInspectorWebSocket>,
    ): List<HarEntry> {
        return buildList {
            requests.forEach { request -> add(requestToEntry(request)) }
            webSockets.forEach { webSocket -> add(webSocketToEntry(webSocket)) }
        }.sortedBy { entry -> entry.startedDateTime }
    }

    private data class RequestEntryParts(
        val startedAt: Instant,
        val request: HarRequest,
        val response: HarResponse,
        val timings: HarTimings,
        val fallbackDurationMs: Long,
    )

    private data class ResponsePayload(
        val bodyText: String?,
        val mimeType: String,
        val encoding: String?,
        val contentSize: Long,
    )

    private data class WebSocketEntryParts(
        val startedAt: Instant,
        val durationMs: Double,
        val request: HarRequest,
        val response: HarResponse,
        val timings: HarTimings,
        val webSocketMessages: List<HarWebSocketMessage>,
    )

    private fun requestToEntry(
        request: NetworkInspectorRequest,
    ): HarEntry {
        val parts = requestEntryParts(request)
        return HarEntry(
            startedDateTime = parts.startedAt.toString(),
            time = entryTimeMs(timings = parts.timings, fallbackDurationMs = parts.fallbackDurationMs),
            request = parts.request,
            response = parts.response,
            cache = HarCache(),
            timings = parts.timings,
        )
    }

    private fun requestEntryParts(
        request: NetworkInspectorRequest,
    ): RequestEntryParts {
        val requestRecord = request.request
        val responseRecord = request.response
        val failureRecord = request.failure

        val requestHeaders = requestRecord?.headers.orEmpty()
        val responseHeaders = responseRecord?.headers.orEmpty()

        val startedAt = requestRecord?.tWallMs?.let(Instant::ofEpochMilli) ?: request.firstSeenAt
        val timings = requestTimings()
        val fallbackDurationMs = requestDurationFallbackMs(
            startWallMs = requestRecord?.tWallMs,
            endWallMs = failureRecord?.tWallMs ?: responseRecord?.tWallMs,
            fallbackEnd = request.lastUpdatedAt,
            fallbackStart = request.firstSeenAt,
        )

        return RequestEntryParts(
            startedAt = startedAt,
            request = requestRecordToHarRequest(requestRecord, requestHeaders),
            response = requestToHarResponse(
                request = request,
                responseRecord = responseRecord,
                failureRecord = failureRecord,
                responseHeaders = responseHeaders,
            ),
            timings = timings,
            fallbackDurationMs = fallbackDurationMs,
        )
    }

    private fun requestRecordToHarRequest(
        requestRecord: RequestWillBeSent?,
        requestHeaders: List<Header>,
    ): HarRequest {
        val requestBodyRaw = requestRecord?.body ?: requestRecord?.bodyPreview
        val mimeType = contentTypeFromHeaders(requestHeaders) ?: "x-unknown"
        return HarRequest(
            method = requestRecord?.method ?: "GET",
            url = requestRecord?.url ?: "about:blank",
            httpVersion = "unknown",
            headers = toHarHeaders(requestHeaders, context = HarHeaderContext.Request),
            queryString = queryStringFor(requestRecord?.url),
            cookies = emptyList(),
            headersSize = -1,
            bodySize = requestBodySize(requestRecord, requestBodyRaw),
            postData = requestBodyRaw?.let { body ->
                HarPostData(
                    mimeType = mimeType,
                    text = body,
                )
            },
        )
    }

    private fun requestToHarResponse(
        request: NetworkInspectorRequest,
        responseRecord: ResponseReceived?,
        failureRecord: RequestFailed?,
        responseHeaders: List<Header>,
    ): HarResponse {
        val payload = responsePayload(
            request = request,
            responseRecord = responseRecord,
        )
        return HarResponse(
            status = responseRecord?.code ?: 0,
            statusText = failureRecord?.message ?: failureRecord?.errorKind.orEmpty(),
            httpVersion = "unknown",
            headers = toHarHeaders(responseHeaders, context = HarHeaderContext.Response),
            cookies = emptyList(),
            content = HarContent(
                size = payload.contentSize,
                mimeType = payload.mimeType,
                text = payload.bodyText,
                encoding = payload.encoding,
            ),
            redirectURL = responseHeaders.firstOrNull { header ->
                header.name.equals("Location", ignoreCase = true)
            }?.value.orEmpty(),
            headersSize = -1,
            bodySize = responseBodySize(response = responseRecord, contentSize = payload.contentSize),
            error = failureRecord?.message ?: failureRecord?.errorKind,
        )
    }

    private fun responsePayload(
        request: NetworkInspectorRequest,
        responseRecord: ResponseReceived?,
    ): ResponsePayload {
        val bodyTextRaw = responseBodyText(request = request)
        val mimeType = responseMimeType(responseRecord, request)
        val bodyText = bodyTextRaw
        val encoding = responseEncoding(
            mimeType = mimeType,
            bodyText = bodyText,
            fromStreamEvents = shouldMarkAsStreamEventBody(bodyText, responseRecord, request),
            response = responseRecord,
        )
        val contentSize = responseContentSize(
            response = responseRecord,
            bodyText = bodyText,
            encoding = encoding,
            request = request,
        )
        return ResponsePayload(
            bodyText = bodyText,
            mimeType = mimeType,
            encoding = encoding,
            contentSize = contentSize,
        )
    }

    private fun webSocketToEntry(
        webSocket: NetworkInspectorWebSocket,
    ): HarEntry {
        val parts = webSocketEntryParts(webSocket)
        return HarEntry(
            startedDateTime = parts.startedAt.toString(),
            time = parts.durationMs,
            request = parts.request,
            response = parts.response,
            cache = HarCache(),
            timings = parts.timings,
            resourceType = "websocket",
            webSocketMessages = parts.webSocketMessages,
        )
    }

    private fun webSocketEntryParts(
        webSocket: NetworkInspectorWebSocket,
    ): WebSocketEntryParts {
        val willOpen = webSocket.willOpen
        val requestHeaders = willOpen?.headers.orEmpty()
        val responseHeaders = webSocket.opened?.headers.orEmpty()

        val startedAt = willOpen?.tWallMs?.let(Instant::ofEpochMilli) ?: webSocket.firstSeenAt
        val durationMs = webSocketDurationMs(webSocket = webSocket, startedAt = startedAt)

        return WebSocketEntryParts(
            startedAt = startedAt,
            durationMs = durationMs,
            request = HarRequest(
                method = "GET",
                url = willOpen?.url ?: "ws://${webSocket.socketId}",
                httpVersion = "HTTP/1.1",
                headers = toHarHeaders(requestHeaders, context = HarHeaderContext.Request),
                queryString = queryStringFor(willOpen?.url),
                cookies = emptyList(),
                headersSize = -1,
                bodySize = 0,
                postData = null,
            ),
            response = HarResponse(
                status = webSocket.opened?.code ?: 0,
                statusText = webSocket.failed?.message.orEmpty(),
                httpVersion = "HTTP/1.1",
                headers = toHarHeaders(responseHeaders, context = HarHeaderContext.Response),
                cookies = emptyList(),
                content = HarContent(size = 0, mimeType = "x-unknown"),
                redirectURL = "",
                headersSize = -1,
                bodySize = 0,
                error = webSocket.failed?.message,
            ),
            timings = HarTimings(
                blocked = -1.0,
                dns = -1.0,
                connect = -1.0,
                send = 0.0,
                wait = durationMs,
                receive = 0.0,
                ssl = -1.0,
            ),
            webSocketMessages = webSocketMessages(webSocket),
        )
    }

    private fun webSocketDurationMs(
        webSocket: NetworkInspectorWebSocket,
        startedAt: Instant,
    ): Double {
        val endAtMs = webSocket.closed?.tWallMs
            ?: webSocket.failed?.tWallMs
            ?: webSocket.cancelled?.tWallMs
            ?: webSocket.messages.lastOrNull()?.tWallMs
            ?: webSocket.lastUpdatedAt.toEpochMilli()
        return max(0L, endAtMs - startedAt.toEpochMilli()).toDouble()
    }

    private fun webSocketMessages(
        webSocket: NetworkInspectorWebSocket,
    ): List<HarWebSocketMessage> {
        return webSocket.messages.map { message ->
            HarWebSocketMessage(
                type = when (message.direction) {
                    WebSocketMessage.Direction.Outgoing -> "send"
                    WebSocketMessage.Direction.Incoming -> "receive"
                },
                time = message.tWallMs / 1000.0,
                opcode = webSocketOpcode(message.opcode),
                data = message.preview.orEmpty(),
            )
        }
    }

    private fun responseBodyText(request: NetworkInspectorRequest): String? {
        val responseBody = request.response?.body ?: request.response?.bodyPreview
        if (responseBody != null) return responseBody
        if (request.streamEvents.isEmpty()) return null
        return joinSseEvents(request.streamEvents)
    }

    private fun shouldMarkAsStreamEventBody(
        responseBodyText: String?,
        responseRecord: ResponseReceived?,
        request: NetworkInspectorRequest,
    ): Boolean {
        return responseBodyText != null &&
            responseRecord?.body == null &&
            request.streamEvents.isNotEmpty()
    }

    private fun joinSseEvents(events: List<ResponseStreamEvent>): String {
        return events
            .sortedWith(compareBy<ResponseStreamEvent> { it.sequence }.thenBy { it.tWallMs })
            .joinToString(separator = "") { event ->
                val normalized = event.raw.replace(Regex("\\n+$"), "")
                normalized + "\n\n"
            }
    }

    private fun responseMimeType(
        response: ResponseReceived?,
        request: NetworkInspectorRequest,
    ): String {
        val fromHeaders = contentTypeFromHeaders(response?.headers.orEmpty())
        if (!fromHeaders.isNullOrBlank()) return fromHeaders
        if (request.streamEvents.isNotEmpty()) return "text/event-stream"
        return "x-unknown"
    }

    private fun responseEncoding(
        mimeType: String,
        bodyText: String?,
        fromStreamEvents: Boolean,
        response: ResponseReceived?,
    ): String? {
        if (bodyText == null || fromStreamEvents) return null
        if (response?.bodyBase64Encoded == true) return "base64"
        if (response?.bodyEncoding.equals("base64", ignoreCase = true)) return "base64"
        if (mimeType.isTextLikeMimeType()) return null
        return if (isLikelyBase64(bodyText)) "base64" else null
    }

    private fun responseContentSize(
        response: ResponseReceived?,
        bodyText: String?,
        encoding: String?,
        request: NetworkInspectorRequest,
    ): Long {
        val explicit = response?.bodySize
        if (explicit != null && explicit >= 0) return explicit

        if (bodyText != null) {
            if (encoding == "base64") {
                val normalized = bodyText.filterNot(Char::isWhitespace)
                val decoded = runCatching { Base64.getDecoder().decode(normalized) }.getOrNull()
                if (decoded != null) return decoded.size.toLong()
            }
            return bodyText.toByteArray(Charsets.UTF_8).size.toLong()
        }

        request.streamClosed?.totalBytes?.let { totalBytes ->
            if (totalBytes >= 0) return totalBytes
        }

        return -1
    }

    private fun responseBodySize(
        response: ResponseReceived?,
        contentSize: Long,
    ): Long {
        val explicit = response?.bodySize
        if (explicit != null && explicit >= 0) return explicit
        return contentSize
    }

    private fun requestBodySize(
        request: RequestWillBeSent?,
        bodyText: String?,
    ): Long {
        val explicit = request?.bodySize
        if (explicit != null && explicit >= 0) return explicit
        return bodyText?.toByteArray(Charsets.UTF_8)?.size?.toLong() ?: -1
    }

    private fun requestTimings(): HarTimings {
        return HarTimings(
            blocked = -1.0,
            dns = -1.0,
            connect = -1.0,
            send = -1.0,
            wait = -1.0,
            receive = -1.0,
            ssl = -1.0,
        )
    }

    private fun entryTimeMs(
        timings: HarTimings,
        fallbackDurationMs: Long,
    ): Double {
        val sum = listOf(
            timings.blocked,
            timings.dns,
            timings.connect,
            timings.send,
            timings.wait,
            timings.receive,
        ).sumOf { value -> if (value >= 0) value else 0.0 }
        return if (sum > 0) sum else fallbackDurationMs.toDouble()
    }

    private fun requestDurationFallbackMs(
        startWallMs: Long?,
        endWallMs: Long?,
        fallbackStart: Instant,
        fallbackEnd: Instant,
    ): Long {
        val start = startWallMs ?: fallbackStart.toEpochMilli()
        val end = endWallMs ?: fallbackEnd.toEpochMilli()
        return max(0L, end - start)
    }

    private fun contentTypeFromHeaders(headers: List<Header>): String? {
        val raw = headers.firstOrNull { header ->
            header.name.equals("Content-Type", ignoreCase = true)
        }?.value ?: return null
        return raw.substringBefore(';').trim().lowercase().ifBlank { null }
    }

    private fun toHarHeaders(
        headers: List<Header>,
        context: HarHeaderContext,
    ): List<HarHeader> {
        return headers
            .filterNot { header -> shouldDropHeader(header.name, context) }
            .map { header ->
                HarHeader(
                    name = header.name,
                    value = header.value,
                )
            }
    }

    private fun queryStringFor(
        url: String?,
    ): List<HarNameValue> {
        val resolvedUrl = url ?: return emptyList()
        val rawQuery = runCatching { URI(resolvedUrl).rawQuery }.getOrNull() ?: return emptyList()
        if (rawQuery.isBlank()) return emptyList()

        return rawQuery
            .split('&')
            .filter { component -> component.isNotEmpty() }
            .map { component ->
                val separator = component.indexOf('=')
                val rawName = if (separator == -1) component else component.substring(0, separator)
                val rawValue = if (separator == -1) "" else component.substring(separator + 1)
                val decodedName = decodeUriComponent(rawName)
                val decodedValue = decodeUriComponent(rawValue)
                HarNameValue(
                    name = decodedName,
                    value = decodedValue,
                )
            }
    }

    private fun shouldDropHeader(
        headerName: String,
        context: HarHeaderContext,
    ): Boolean {
        return when (context) {
            HarHeaderContext.Request -> {
                headerName.equals("Authorization", ignoreCase = true) ||
                    headerName.equals("Cookie", ignoreCase = true)
            }

            HarHeaderContext.Response -> headerName.equals("Set-Cookie", ignoreCase = true)
        }
    }

    private fun decodeUriComponent(value: String): String {
        if (value.isEmpty()) return value
        return runCatching { URLDecoder.decode(value, Charsets.UTF_8) }.getOrDefault(value)
    }

    private fun webSocketOpcode(opcode: String): Int {
        return when (opcode.lowercase()) {
            "text" -> 1
            "binary" -> 2
            "close" -> 8
            "ping" -> 9
            "pong" -> 10
            else -> opcode.toIntOrNull() ?: -1
        }
    }

    private fun isLikelyBase64(value: String): Boolean {
        val normalized = value.filterNot(Char::isWhitespace)
        if (normalized.length < 16) return false
        if (normalized.length % 4 != 0) return false
        if (!normalized.all(::isBase64AlphabetChar)) return false
        return runCatching { Base64.getDecoder().decode(normalized) }.isSuccess
    }

    private fun isBase64AlphabetChar(ch: Char): Boolean {
        return ch.isLetterOrDigit() || ch == '+' || ch == '/' || ch == '='
    }

    private fun String.isTextLikeMimeType(): Boolean {
        if (startsWith("text/")) return true
        return contains("json") ||
            contains("xml") ||
            contains("html") ||
            contains("javascript") ||
            contains("graphql") ||
            contains("x-www-form-urlencoded")
    }

    private fun defaultFileName(entryCount: Int): String {
        val stamp = fileNameTimestampFormatter.format(Instant.now())
        return if (entryCount <= 1) {
            "snapo-request-$stamp.har"
        } else {
            "snapo-requests-$entryCount-$stamp.har"
        }
    }
}

@Serializable
private data class HarRoot(
    val log: HarLog,
)

@Serializable
private data class HarLog(
    val version: String = "1.2",
    val creator: HarCreator,
    val pages: List<HarPage> = emptyList(),
    val entries: List<HarEntry>,
)

@Serializable
private data class HarCreator(
    val name: String,
    val version: String,
)

@Serializable
private data class HarPage(
    val startedDateTime: String,
    val id: String,
    val title: String,
    val pageTimings: HarPageTimings,
)

@Serializable
private data class HarPageTimings(
    val onContentLoad: Double,
    val onLoad: Double,
)

@Serializable
private data class HarEntry(
    val startedDateTime: String,
    val time: Double,
    val request: HarRequest,
    val response: HarResponse,
    val cache: HarCache,
    val timings: HarTimings,
    @SerialName("_resourceType")
    val resourceType: String? = null,
    @SerialName("_webSocketMessages")
    val webSocketMessages: List<HarWebSocketMessage>? = null,
)

@Serializable
private data class HarRequest(
    val method: String,
    val url: String,
    val httpVersion: String,
    val headers: List<HarHeader>,
    val queryString: List<HarNameValue>,
    val cookies: List<HarCookie>,
    val headersSize: Int,
    val bodySize: Long,
    val postData: HarPostData? = null,
)

@Serializable
private data class HarResponse(
    val status: Int,
    val statusText: String,
    val httpVersion: String,
    val headers: List<HarHeader>,
    val cookies: List<HarCookie>,
    val content: HarContent,
    val redirectURL: String,
    val headersSize: Int,
    val bodySize: Long,
    @SerialName("_error")
    val error: String? = null,
)

@Serializable
private data class HarHeader(
    val name: String,
    val value: String,
)

@Serializable
private data class HarNameValue(
    val name: String,
    val value: String,
)

@Serializable
private data class HarCookie(
    val name: String,
    val value: String,
)

@Serializable
private data class HarContent(
    val size: Long,
    val mimeType: String,
    val text: String? = null,
    val encoding: String? = null,
)

@Serializable
private data class HarPostData(
    val mimeType: String,
    val text: String,
)

@Serializable
private data class HarTimings(
    val blocked: Double,
    val dns: Double,
    val connect: Double,
    val send: Double,
    val wait: Double,
    val receive: Double,
    val ssl: Double,
)

@Serializable
private class HarCache

@Serializable
private data class HarWebSocketMessage(
    val type: String,
    val time: Double,
    val opcode: Int,
    val data: String,
)

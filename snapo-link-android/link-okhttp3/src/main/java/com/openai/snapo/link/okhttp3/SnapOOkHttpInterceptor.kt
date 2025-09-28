package com.openai.snapo.link.okhttp3

import android.os.SystemClock
import android.util.Base64.NO_WRAP
import android.util.Base64.encodeToString
import com.openai.snapo.link.core.RequestFailed
import com.openai.snapo.link.core.ResponseStreamClosed
import com.openai.snapo.link.core.ResponseStreamEvent
import com.openai.snapo.link.core.SnapOLink
import com.openai.snapo.link.core.SnapONetRecord
import com.openai.snapo.link.core.Timings
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.Source
import okio.buffer
import java.io.Closeable
import java.io.IOException
import java.nio.charset.Charset
import java.util.ArrayList
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/** OkHttp interceptor that mirrors traffic to the active SnapO link if present. */
class SnapOOkHttpInterceptor @JvmOverloads constructor(
    private val responseBodyPreviewBytes: Int = DefaultBodyPreviewBytes,
    private val textBodyMaxBytes: Int = DefaultTextBodyMaxBytes,
    dispatcher: CoroutineDispatcher = DefaultDispatcher,
) : Interceptor, Closeable {

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    override fun intercept(chain: Interceptor.Chain): Response {
        val context = InterceptContext(
            requestId = UUID.randomUUID().toString(),
            startWall = System.currentTimeMillis(),
            startMono = SystemClock.elapsedRealtimeNanos(),
        )

        val request = chain.request()
        publishRequest(context, request)

        return try {
            val response = chain.proceed(request)
            handleResponse(context, response)
        } catch (t: Throwable) {
            handleFailure(context, t)
            throw t
        }
    }

    override fun close() {
        scope.cancel()
    }

    private fun publishRequest(context: InterceptContext, request: Request) {
        val requestBody = request.captureBody(textBodyMaxBytes)
        publish {
            var encoding: String? = null
            val encodedBody: String? = when {
                requestBody == null -> null

                requestBody.contentType.isTextLike() -> {
                    val charset = requestBody.contentType.resolveCharset()
                    String(requestBody.body, charset)
                }

                else -> {
                    encoding = "base64"
                    encodeToString(requestBody.body, NO_WRAP)
                }
            }
            OkhttpEventFactory.createRequestWillBeSent(
                context,
                request,
                body = encodedBody,
                bodyEncoding = encoding,
                truncatedBytes = requestBody?.truncatedBytes,
            )
        }
    }

    private fun handleResponse(context: InterceptContext, response: Response): Response {
        val endWall = System.currentTimeMillis()
        val endMono = SystemClock.elapsedRealtimeNanos()
        val responseBody = response.body
        return if (responseBody.contentType().isEventStream()) {
            handleStreamingResponse(context, response, responseBody, endWall = endWall, endMono = endMono)
        } else {
            publishStandardResponse(context, response, responseBody, endWall = endWall, endMono = endMono)
            response
        }
    }

    private fun handleStreamingResponse(
        context: InterceptContext,
        response: Response,
        body: ResponseBody,
        endWall: Long,
        endMono: Long,
    ): Response {
        publish {
            OkhttpEventFactory.createResponseReceived(
                context = context,
                response = response,
                endWall = endWall,
                endMono = endMono,
                bodyPreview = null,
                bodyText = null,
                truncatedBytes = null,
                bodySize = body.safeContentLength(),
            )
        }

        val relay = ResponseStreamRelay(
            requestId = context.requestId,
            charset = body.contentType().resolveCharset(),
        )
        val streamingBody = StreamingResponseBody(body, relay)
        return response.newBuilder().body(streamingBody).build()
    }

    private fun publishStandardResponse(
        context: InterceptContext,
        response: Response,
        body: ResponseBody,
        endWall: Long,
        endMono: Long,
    ) {
        val bodySize = body.safeContentLength()
        val textBody = response.captureTextBody(textBodyMaxBytes, responseBodyPreviewBytes)
        val bodyPreview = textBody?.preview ?: response.bodyPreview(responseBodyPreviewBytes.toLong())
        val truncatedBytes = textBody?.truncatedBytes(bodySize)

        publish {
            OkhttpEventFactory.createResponseReceived(
                context = context,
                response = response,
                endWall = endWall,
                endMono = endMono,
                bodyPreview = bodyPreview,
                bodyText = textBody?.body,
                truncatedBytes = truncatedBytes,
                bodySize = bodySize,
            )
        }
    }

    private fun handleFailure(context: InterceptContext, error: Throwable) {
        val failWall = System.currentTimeMillis()
        val failMono = SystemClock.elapsedRealtimeNanos()
        publish {
            RequestFailed(
                id = context.requestId,
                tWallMs = failWall,
                tMonoNs = failMono,
                errorKind = error.javaClass.simpleName.ifEmpty { error.javaClass.name },
                message = error.message,
                timings = Timings(totalMs = nanosToMillis(failMono - context.startMono)),
            )
        }
    }

    private inline fun publish(crossinline builder: () -> SnapONetRecord) {
        val server = SnapOLink.serverOrNull() ?: return
        val record = builder()
        scope.launch {
            try {
                server.publish(record)
            } catch (_: Throwable) {
            }
        }
    }

    private inner class StreamingResponseBody(
        private val delegate: ResponseBody,
        private val relay: ResponseStreamRelay,
    ) : ResponseBody() {

        private val bufferedSource: BufferedSource by lazy {
            relay.wrapSource(delegate.source()).buffer()
        }

        override fun contentType(): MediaType? = delegate.contentType()

        override fun contentLength(): Long = delegate.contentLength()

        override fun source(): BufferedSource = bufferedSource

        override fun close() {
            try {
                bufferedSource.close()
            } finally {
                relay.onClosed(null)
            }
        }
    }

    private inner class ResponseStreamRelay(
        private val requestId: String,
        charset: Charset,
    ) {
        private val closed = AtomicBoolean(false)
        private val parser = SseBuffer(charset)
        private var nextSequence: Long = 0L
        private var totalBytes: Long = 0L

        fun wrapSource(upstream: Source): Source {
            return object : ForwardingSource(upstream) {
                override fun read(sink: Buffer, byteCount: Long): Long {
                    return try {
                        val read = super.read(sink, byteCount)
                        if (read > 0) {
                            val copy = Buffer()
                            sink.copyTo(copy, sink.size - read, read)
                            handleBytes(copy.readByteArray())
                        } else if (read == -1L) {
                            onClosed(null)
                        }
                        read
                    } catch (t: Throwable) {
                        onClosed(t)
                        throw t
                    }
                }

                override fun close() {
                    try {
                        super.close()
                    } finally {
                        onClosed(null)
                    }
                }
            }
        }

        private fun handleBytes(bytes: ByteArray) {
            val events = synchronized(this) {
                totalBytes += bytes.size
                parser.append(bytes).map { raw ->
                    val sequence = ++nextSequence
                    raw.toParsedSseEvent(sequence)
                }
            }
            publishEvents(events)
        }

        fun onClosed(error: Throwable?) {
            if (!closed.compareAndSet(false, true)) return
            val tailEvents = synchronized(this) {
                parser.drainRemaining().map { raw ->
                    val sequence = ++nextSequence
                    raw.toParsedSseEvent(sequence)
                }
            }
            publishEvents(tailEvents)

            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            publish {
                ResponseStreamClosed(
                    id = requestId,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    reason = if (error == null) "completed" else "error",
                    message = error?.message ?: error?.javaClass?.simpleName,
                    totalEvents = nextSequence,
                    totalBytes = totalBytes,
                )
            }
        }

        private fun publishEvents(events: List<ParsedSseEvent>) {
            for (event in events) {
                val nowWall = System.currentTimeMillis()
                val nowMono = SystemClock.elapsedRealtimeNanos()
                publish {
                    ResponseStreamEvent(
                        id = requestId,
                        tWallMs = nowWall,
                        tMonoNs = nowMono,
                        sequence = event.sequence,
                        event = event.eventName,
                        data = event.data,
                        lastEventId = event.lastEventId,
                        retryMillis = event.retryMillis,
                        comment = event.comment,
                        raw = event.raw,
                    )
                }
            }
        }
    }
}

internal data class InterceptContext(
    val requestId: String,
    val startWall: Long,
    val startMono: Long,
)

private class SseBuffer(private val charset: Charset) {
    private val buffer = StringBuilder()

    fun append(bytes: ByteArray): List<String> {
        if (bytes.isEmpty()) return emptyList()
        buffer.append(bytes.toNormalizedString(charset))
        return drainInternal(flushTail = false)
    }

    fun drainRemaining(): List<String> = drainInternal(flushTail = true)

    private fun drainInternal(flushTail: Boolean): List<String> {
        if (buffer.isEmpty()) return emptyList()
        val events = ArrayList<String>()
        while (true) {
            val boundary = buffer.indexOf("\n\n")
            if (boundary < 0) {
                if (flushTail && buffer.isNotEmpty()) {
                    events += buffer.toString()
                    buffer.setLength(0)
                }
                return events
            }
            events += buffer.substring(0, boundary)
            buffer.delete(0, boundary + 2)
        }
    }
}

private data class ParsedSseEvent(
    val sequence: Long,
    val raw: String,
    val eventName: String?,
    val data: String?,
    val lastEventId: String?,
    val retryMillis: Long?,
    val comment: String?,
)

private data class TextBodyCapture(
    val body: String,
    val preview: String?,
    val truncated: Boolean,
    val capturedBytes: Long,
    val originalBytes: Long,
)

internal data class RequestBodyCapture(
    val contentType: MediaType?,
    val body: ByteArray,
    val truncatedBytes: Long,
)

private fun ResponseBody?.safeContentLength(): Long? = this?.let {
    try {
        it.contentLength().takeIf { len -> len >= 0L }
    } catch (_: IOException) {
        null
    }
}

private fun Response.bodyPreview(maxBytes: Long): String? {
    return if (maxBytes <= 0L) {
        null
    } else {
        try {
            val limit = maxBytes.coerceAtMost(Int.MAX_VALUE.toLong())
            val peek: ResponseBody = peekBody(limit)
            val bytes = peek.bytes()
            val charset: Charset = peek.contentType().resolveCharset()
            String(bytes, charset)
        } catch (_: IOException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }
}

private fun MediaType?.isTextLike(): Boolean {
    val mediaType = this ?: return false
    val typeLower = mediaType.type.lowercase()
    if (typeLower == "text") return true
    val subtypeLower = mediaType.subtype.lowercase()
    val textualHints = listOf(
        "json",
        "xml",
        "html",
        "javascript",
        "form",
        "graphql",
        "plain",
        "csv",
        "yaml",
    )
    return textualHints.any(subtypeLower::contains)
}

private fun MediaType?.isEventStream(): Boolean {
    val mediaType = this ?: return false
    return mediaType.type.equals("text", ignoreCase = true) &&
        mediaType.subtype.equals("event-stream", ignoreCase = true)
}

private fun Response.captureTextBody(maxBytes: Int, previewBytes: Int): TextBodyCapture? {
    val responseBody = body
    val mediaType = responseBody.contentType()
    return when {
        maxBytes <= 0L -> null
        mediaType?.isTextLike() != true -> null
        else -> try {
            val peek = peekBody(maxBytes.toLong() + 1L)
            val bytes = peek.bytes()
            val truncated = bytes.size > maxBytes
            val effective = if (truncated) bytes.copyOf(maxBytes) else bytes
            val charset = mediaType.resolveCharset()
            val text = String(effective, charset)
            val previewLimit = previewBytes
                .coerceAtMost(effective.size)
            val preview = if (previewLimit > 0) {
                String(effective, 0, previewLimit, charset)
            } else {
                null
            }
            TextBodyCapture(
                body = text,
                preview = preview,
                truncated = truncated,
                capturedBytes = effective.size.toLong(),
                originalBytes = bytes.size.toLong(),
            )
        } catch (_: IOException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }
}

private fun Request.captureBody(maxBytes: Int): RequestBodyCapture? {
    if (maxBytes <= 0) return null
    val requestBody = body ?: return null
    if (requestBody.isDuplex() || requestBody.isOneShot()) return null

    return try {
        val buffer = Buffer()
        requestBody.writeTo(buffer)
        val totalBytes = buffer.size
        val capturedBytesCount = totalBytes.coerceAtMost(maxBytes.toLong()).toInt()
        val body = buffer.readByteArray(capturedBytesCount.toLong())
        val truncatedBytes = (totalBytes - body.size.toLong()).coerceAtLeast(0L)

        RequestBodyCapture(
            contentType = requestBody.contentType(),
            body = body,
            truncatedBytes = truncatedBytes,
        )
    } catch (_: IOException) {
        null
    } catch (_: RuntimeException) {
        null
    }
}

private fun TextBodyCapture.truncatedBytes(totalBytes: Long?): Long? {
    return when {
        totalBytes != null -> max(totalBytes - capturedBytes, 0L)
        truncated -> max(originalBytes - capturedBytes, 0L)
        else -> null
    }
}

private fun MediaType?.resolveCharset(): Charset {
    return try {
        this?.charset(Charsets.UTF_8) ?: Charsets.UTF_8
    } catch (_: IllegalArgumentException) {
        Charsets.UTF_8
    }
}

internal fun nanosToMillis(deltaNs: Long): Long? {
    if (deltaNs <= 0L) return null
    return TimeUnit.NANOSECONDS.toMillis(deltaNs)
}

private fun ByteArray.toNormalizedString(charset: Charset): String {
    val raw = String(this, charset)
    if (raw.indexOf('\r') == -1) return raw
    return raw.replace("\r\n", "\n").replace('\r', '\n')
}

private fun String.toParsedSseEvent(sequence: Long): ParsedSseEvent {
    var eventName: String? = null
    var lastEventId: String? = null
    var retryMillis: Long? = null
    val comments = mutableListOf<String>()
    val dataLines = mutableListOf<String>()

    for (line in lineSequence()) {
        when {
            line.isEmpty() -> Unit
            line.startsWith(":") -> {
                val comment = line.substring(1).trimStart()
                if (comment.isNotEmpty()) {
                    comments += comment
                }
            }

            else -> {
                val (field, value) = line.splitField()
                when (field) {
                    "event" -> eventName = value
                    "data" -> dataLines += value
                    "id" -> lastEventId = value
                    "retry" -> retryMillis = value.toLongOrNull()
                }
            }
        }
    }

    val data = when {
        dataLines.isEmpty() && isEmpty() -> ""
        dataLines.isEmpty() -> null
        else -> dataLines.joinToString("\n")
    }

    val comment = comments.takeIf { it.isNotEmpty() }?.joinToString("\n")

    return ParsedSseEvent(
        sequence = sequence,
        raw = this,
        eventName = eventName,
        data = data,
        lastEventId = lastEventId,
        retryMillis = retryMillis,
        comment = comment,
    )
}

private fun String.splitField(): Pair<String, String> {
    val colonIndex = indexOf(':')
    if (colonIndex < 0) {
        return this to ""
    }
    val field = substring(0, colonIndex)
    val value = substring(colonIndex + 1).removePrefix(" ")
    return field to value
}

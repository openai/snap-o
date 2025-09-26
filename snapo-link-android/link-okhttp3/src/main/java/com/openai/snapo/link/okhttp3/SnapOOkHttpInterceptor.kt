package com.openai.snapo.link.okhttp3

import android.os.SystemClock
import android.util.Base64
import com.openai.snapo.link.core.Header
import com.openai.snapo.link.core.RequestFailed
import com.openai.snapo.link.core.RequestWillBeSent
import com.openai.snapo.link.core.ResponseReceived
import com.openai.snapo.link.core.ResponseStreamClosed
import com.openai.snapo.link.core.ResponseStreamEvent
import com.openai.snapo.link.core.SnapOLink
import com.openai.snapo.link.core.SnapONetRecord
import com.openai.snapo.link.core.Timings
import java.io.Closeable
import java.io.IOException
import java.nio.charset.Charset
import java.util.ArrayList
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.Source
import okio.buffer

/** OkHttp interceptor that mirrors traffic to the active SnapO link if present. */
class SnapOOkHttpInterceptor @JvmOverloads constructor(
    private val responseBodyPreviewBytes: Long = DefaultBodyPreviewBytes,
    private val textBodyMaxBytes: Long = DefaultTextBodyMaxBytes,
    dispatcher: CoroutineDispatcher = DefaultDispatcher,
) : Interceptor, Closeable {

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val requestId = UUID.randomUUID().toString()
        val startWall = System.currentTimeMillis()
        val startMono = SystemClock.elapsedRealtimeNanos()

        val requestBodyCapture = request.captureBody(
            maxBytes = textBodyMaxBytes,
            previewBytes = responseBodyPreviewBytes,
        )

        publish {
            RequestWillBeSent(
                id = requestId,
                tWallMs = startWall,
                tMonoNs = startMono,
                method = request.method,
                url = request.url.toString(),
                headers = request.headers.toHeaderList(),
                bodyPreview = requestBodyCapture?.preview,
                body = requestBodyCapture?.body,
                bodyEncoding = requestBodyCapture?.encoding,
                bodyTruncatedBytes = requestBodyCapture?.truncatedBytes,
                bodySize = request.body.safeContentLength(),
            )
        }

        return try {
            val response = chain.proceed(request)
            val endWall = System.currentTimeMillis()
            val endMono = SystemClock.elapsedRealtimeNanos()

            val responseBody = response.body
            if (responseBody.contentType().isEventStream()) {
                val relay = ResponseStreamRelay(
                    requestId = requestId,
                    charset = responseBody.contentType().resolveCharset(),
                )
                val streamingBody = StreamingResponseBody(responseBody, relay)

                publish {
                    ResponseReceived(
                        id = requestId,
                        tWallMs = endWall,
                        tMonoNs = endMono,
                        code = response.code,
                        headers = response.headers.toHeaderList(),
                        bodyPreview = null,
                        body = null,
                        bodyTruncatedBytes = null,
                        bodySize = responseBody.safeContentLength(),
                        timings = Timings(totalMs = nanosToMillis(endMono - startMono)),
                    )
                }

                response.newBuilder()
                    .body(streamingBody)
                    .build()
            } else {
                val bodySize = responseBody.safeContentLength()
                val textBody = response.captureTextBody(textBodyMaxBytes, responseBodyPreviewBytes)
                val bodyPreview = textBody?.preview ?: response.bodyPreview(responseBodyPreviewBytes)
                val truncatedBytes = textBody?.truncatedBytes(bodySize)

                publish {
                    ResponseReceived(
                        id = requestId,
                        tWallMs = endWall,
                        tMonoNs = endMono,
                        code = response.code,
                        headers = response.headers.toHeaderList(),
                        bodyPreview = bodyPreview,
                        body = textBody?.body,
                        bodyTruncatedBytes = truncatedBytes,
                        bodySize = bodySize,
                        timings = Timings(totalMs = nanosToMillis(endMono - startMono)),
                    )
                }

                response
            }
        } catch (t: Throwable) {
            val failWall = System.currentTimeMillis()
            val failMono = SystemClock.elapsedRealtimeNanos()

            publish {
                RequestFailed(
                    id = requestId,
                    tWallMs = failWall,
                    tMonoNs = failMono,
                    errorKind = t.javaClass.simpleName.ifEmpty { t.javaClass.name },
                    message = t.message,
                    timings = Timings(totalMs = nanosToMillis(failMono - startMono)),
                )
            }

            throw t
        }
    }

    override fun close() {
        scope.cancel()
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

    private fun Headers.toHeaderList(): List<Header> {
        if (size == 0) return emptyList()
        val result = ArrayList<Header>(size)
        for (index in 0 until size) {
            result += Header(name(index), value(index))
        }
        return result
    }

    private fun RequestBody?.safeContentLength(): Long? = this?.let {
        try {
            it.contentLength().takeIf { len -> len >= 0L }
        } catch (_: IOException) {
            null
        }
    }

    private fun ResponseBody?.safeContentLength(): Long? = this?.let {
        try {
            it.contentLength().takeIf { len -> len >= 0L }
        } catch (_: IOException) {
            null
        }
    }

    private fun Response.bodyPreview(maxBytes: Long): String? {
        if (maxBytes <= 0L) return null
        return try {
            val limit = maxBytes.coerceAtMost(Int.MAX_VALUE.toLong())
            val peek: ResponseBody = peekBody(limit)
            val bytes = peek.bytes()
            val charset: Charset = peek.contentType().resolveCharset()
            String(bytes, charset)
        } catch (_: Throwable) {
            null
        }
    }

    private fun MediaType?.isTextLike(): Boolean {
        if (this == null) return false
        val typeLower = type.lowercase()
        val subtypeLower = subtype.lowercase()
        if (typeLower == "text") return true
        if (subtypeLower.contains("json")) return true
        if (subtypeLower.contains("xml")) return true
        if (subtypeLower.contains("html")) return true
        if (subtypeLower.contains("javascript")) return true
        if (subtypeLower.contains("form")) return true
        if (subtypeLower.contains("graphql")) return true
        if (subtypeLower.contains("plain")) return true
        if (subtypeLower.contains("csv")) return true
        if (subtypeLower.contains("yaml")) return true
        return false
    }

    private fun MediaType?.isEventStream(): Boolean {
        if (this == null) return false
        return type.equals("text", ignoreCase = true) &&
            subtype.equals("event-stream", ignoreCase = true)
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
        private val charset: Charset,
    ) {
        private val closed = AtomicBoolean(false)
        private val buffer = StringBuilder()
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
                            val bytes = copy.readByteArray()
                            handleBytes(bytes)
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
            val events: List<ParsedSseEvent>
            synchronized(this) {
                totalBytes += bytes.size
                buffer.append(normalizeNewlines(String(bytes, charset)))
                events = extractEvents(flushTail = false)
            }
            publishEvents(events)
        }

        fun onClosed(error: Throwable?) {
            if (!closed.compareAndSet(false, true)) return
            val events: List<ParsedSseEvent>
            synchronized(this) {
                events = extractEvents(flushTail = true)
            }
            publishEvents(events)

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

        private fun extractEvents(flushTail: Boolean): List<ParsedSseEvent> {
            if (buffer.isEmpty()) return emptyList()
            val results = ArrayList<ParsedSseEvent>()
            while (true) {
                val boundary = buffer.indexOf("\n\n")
                if (boundary < 0) {
                    if (flushTail) {
                        val raw = buffer.toString()
                        buffer.setLength(0)
                        if (raw.isNotEmpty()) {
                            results += parsePending(raw)
                        }
                    }
                    break
                }

                val raw = buffer.substring(0, boundary)
                buffer.delete(0, boundary + 2)
                results += parsePending(raw)
            }
            return results
        }

        private fun parsePending(raw: String): ParsedSseEvent {
            val sequenceValue = ++nextSequence
            val lines = if (raw.isEmpty()) emptyList() else raw.split('\n')
            val comments = ArrayList<String>()
            val dataBuilder = StringBuilder()
            var eventName: String? = null
            var lastEventId: String? = null
            var retryMillis: Long? = null

            for (line in lines) {
                if (line.isEmpty()) continue
                if (line.startsWith(":")) {
                    val comment = line.substring(1).trimStart()
                    if (comment.isNotEmpty()) {
                        comments += comment
                    }
                    continue
                }

                val colonIndex = line.indexOf(':')
                val field: String
                val value: String
                if (colonIndex < 0) {
                    field = line
                    value = ""
                } else {
                    field = line.substring(0, colonIndex)
                    value = line.substring(colonIndex + 1).removePrefix(" ")
                }

                when (field) {
                    "event" -> eventName = value
                    "data" -> {
                        if (dataBuilder.isNotEmpty()) dataBuilder.append('\n')
                        dataBuilder.append(value)
                    }
                    "id" -> lastEventId = value
                    "retry" -> retryMillis = value.toLongOrNull()
                }
            }

            val data = when {
                dataBuilder.isNotEmpty() -> dataBuilder.toString()
                raw.isEmpty() -> ""
                else -> null
            }

            val comment = if (comments.isEmpty()) null else comments.joinToString("\n")

            return ParsedSseEvent(
                sequence = sequenceValue,
                raw = raw,
                eventName = eventName,
                data = data,
                lastEventId = lastEventId,
                retryMillis = retryMillis,
                comment = comment,
            )
        }

        private fun normalizeNewlines(input: String): String {
            if (input.indexOf('\r') == -1) return input
            return input.replace("\r\n", "\n").replace('\r', '\n')
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

    private fun Response.captureTextBody(maxBytes: Long, previewBytes: Long): TextBodyCapture? {
        if (maxBytes <= 0L) return null
        val responseBody = body ?: return null
        val mediaType = responseBody.contentType()
        if (!mediaType.isTextLike()) return null

        val maxBytesInt = maxBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        return try {
            val peek = peekBody(maxBytesInt.toLong() + 1L)
            val bytes = peek.bytes()
            val truncated = bytes.size > maxBytesInt
            val effective = if (truncated) bytes.copyOf(maxBytesInt) else bytes
            val charset = mediaType.resolveCharset()
            val text = String(effective, charset)
            val previewLimit = previewBytes
                .coerceAtMost(effective.size.toLong())
                .coerceAtMost(Int.MAX_VALUE.toLong())
                .toInt()
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
        } catch (_: Throwable) {
            null
        }
    }

    private data class RequestBodyCapture(
        val body: String,
        val preview: String?,
        val encoding: String?,
        val truncatedBytes: Long,
    )

    private fun Request.captureBody(maxBytes: Long, previewBytes: Long): RequestBodyCapture? {
        if (maxBytes <= 0L) return null
        val requestBody = body ?: return null
        if (requestBody.isDuplex()) return null
        if (requestBody.isOneShot()) return null

        return try {
            val buffer = Buffer()
            requestBody.writeTo(buffer)
            val totalBytes = buffer.size
            val limit = maxBytes.coerceAtMost(Int.MAX_VALUE.toLong())
            val truncated = totalBytes > limit
            val capturedBytes = if (truncated) {
                buffer.clone().readByteArray(limit)
            } else {
                buffer.readByteArray()
            }

            val mediaType = requestBody.contentType()
            val isText = mediaType.isTextLike()
            val (bodyValue, encoding) = if (isText) {
                val charset = mediaType.resolveCharset()
                String(capturedBytes, charset) to null
            } else {
                Base64.encodeToString(capturedBytes, Base64.NO_WRAP) to "base64"
            }

            val truncatedBytes = if (truncated) totalBytes - capturedBytes.size else 0L
            val preview = if (encoding == null && previewBytes > 0L) {
                val previewLimit = previewBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                if (bodyValue.length <= previewLimit) bodyValue else bodyValue.substring(
                    0,
                    previewLimit
                )
            } else {
                null
            }

            RequestBodyCapture(
                body = bodyValue,
                preview = preview,
                encoding = encoding,
                truncatedBytes = truncatedBytes,
            )
        } catch (_: Throwable) {
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
        } catch (_: Throwable) {
            Charsets.UTF_8
        }
    }

    private fun nanosToMillis(deltaNs: Long): Long? {
        if (deltaNs <= 0L) return null
        return TimeUnit.NANOSECONDS.toMillis(deltaNs)
    }
}

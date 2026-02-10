package com.openai.snapo.network.okhttp3

import android.os.SystemClock
import android.util.Base64.NO_WRAP
import android.util.Base64.encodeToString
import com.openai.snapo.link.core.SnapOLink
import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.NetworkInspector
import com.openai.snapo.network.RequestFailed
import com.openai.snapo.network.ResponseFinished
import com.openai.snapo.network.Timings
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSink
import okio.BufferedSource
import okio.ForwardingSink
import okio.ForwardingSource
import okio.buffer
import java.io.Closeable
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/** OkHttp interceptor that mirrors traffic to the active SnapO link if present. */
class SnapOOkHttpInterceptor @JvmOverloads constructor(
    private val responseBodyPreviewBytes: Int = DefaultBodyPreviewBytes,
    private val textBodyMaxBytes: Int = DefaultTextBodyMaxBytes,
    private val binaryBodyMaxBytes: Int = DefaultBinaryBodyMaxBytes,
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
        val requestBody = request.body
        if (requestBody != null && requestBody.isOneShot()) {
            val capturingBody = CapturingRequestBody(requestBody, textBodyMaxBytes)
            val requestWithCapture = request.newBuilder()
                .method(request.method, capturingBody)
                .build()
            var didPublish = false
            fun publishOnce() {
                if (didPublish) return
                didPublish = true
                publishRequest(
                    context = context,
                    request = requestWithCapture,
                    capturedBody = capturingBody.snapshot(),
                    skipFallback = true,
                )
            }

            return runCatching {
                val response = chain.proceed(requestWithCapture)
                publishOnce()
                handleResponse(context, response)
            }.onFailure { error ->
                publishOnce()
                handleFailure(context, error)
            }.getOrThrow()
        }

        publishRequest(context, request)
        return runCatching {
            val response = chain.proceed(request)
            handleResponse(context, response)
        }.onFailure { error ->
            handleFailure(context, error)
        }.getOrThrow()
    }

    override fun close() {
        scope.cancel()
    }

    private fun publishRequest(
        context: InterceptContext,
        request: Request,
        capturedBody: RequestBodyCapture? = null,
        skipFallback: Boolean = false,
    ) {
        val requestBody = if (skipFallback) capturedBody else capturedBody ?: request.captureBody(textBodyMaxBytes)
        val contentType = resolveRequestContentType(requestBody?.contentType, request)
        val contentEncoding = request.header("Content-Encoding")
        val hasCapturedBody = (requestBody?.body?.isNotEmpty() == true) || (requestBody?.truncatedBytes ?: 0L) > 0L
        val hasBody = request.body != null || hasCapturedBody
        publish {
            var encoding: String? = null
            val encodedBody: String? = when {
                requestBody == null -> null

                hasNonIdentityContentEncoding(contentEncoding) -> {
                    encoding = "base64"
                    encodeToString(requestBody.body, NO_WRAP)
                }

                contentType.isMultipartFormData() -> {
                    formatMultipartBody(requestBody.body, contentType)
                }

                contentType.isTextLike() -> {
                    val charset = contentType.resolveCharset()
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
                hasBody = hasBody,
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
        if (response.hasNoBodyByProtocol()) {
            publishStandardResponse(context, response, responseBody, endWall = endWall, endMono = endMono)
            publishLoadingFinished(context, bodySize = 0L)
            return response
        }
        return if (responseBody.contentType().isEventStream()) {
            handleStreamingResponse(context, response, responseBody, endWall = endWall, endMono = endMono)
        } else {
            publishStandardResponse(context, response, responseBody, endWall = endWall, endMono = endMono)
            response.newBuilder()
                .body(
                    CompletionTrackingResponseBody(
                        delegate = responseBody,
                        onFinished = { totalBytes ->
                            publishLoadingFinished(context, totalBytes)
                        },
                        onFailed = { error ->
                            handleFailure(context, error)
                        },
                    ),
                )
                .build()
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
                bodyEncoding = null,
                truncatedBytes = null,
                bodySize = body.safeContentLength(),
            )
        }
        val streamingBody = StreamingResponseRelayBody(
            delegate = body,
            requestId = context.requestId,
            charset = body.contentType().resolveCharset(),
            onRecord = { publish(it) },
        )
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
        publish {
            val textBody = response.captureTextBody(textBodyMaxBytes, responseBodyPreviewBytes)
            val binaryBody = if (textBody == null) {
                response.captureBinaryBody(binaryBodyMaxBytes, responseBodyPreviewBytes)
            } else {
                null
            }
            val bodyPreview = textBody?.preview
                ?: binaryBody?.preview
                ?: response.bodyPreview(responseBodyPreviewBytes)
            val truncatedBytes = textBody?.truncatedBytes(bodySize)
                ?: binaryBody?.truncatedBytes(bodySize)
            val bodyEncoding = if (binaryBody != null) "base64" else null
            OkhttpEventFactory.createResponseReceived(
                context = context,
                response = response,
                endWall = endWall,
                endMono = endMono,
                bodyPreview = bodyPreview,
                bodyText = textBody?.body ?: binaryBody?.base64,
                bodyEncoding = bodyEncoding,
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

    private fun publishLoadingFinished(context: InterceptContext, bodySize: Long?) {
        val finishWall = System.currentTimeMillis()
        val finishMono = SystemClock.elapsedRealtimeNanos()
        publish {
            ResponseFinished(
                id = context.requestId,
                tWallMs = finishWall,
                tMonoNs = finishMono,
                bodySize = bodySize,
            )
        }
    }

    private inline fun publish(crossinline builder: () -> NetworkEventRecord) {
        if (!SnapOLink.isEnabled()) return
        val feature = NetworkInspector.getOrNull() ?: return
        val record = builder()
        scope.launch {
            try {
                feature.publish(record)
            } catch (_: Throwable) {
            }
        }
    }
}

internal data class InterceptContext(
    val requestId: String,
    val startWall: Long,
    val startMono: Long,
)

private data class TextBodyCapture(
    val body: String,
    val preview: String?,
    val truncated: Boolean,
    val capturedBytes: Long,
    val originalBytes: Long,
)

private data class BinaryBodyCapture(
    val base64: String,
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

private class RequestBodyCaptureBuffer(private val maxBytes: Int) {
    private val buffer = Buffer()
    private var totalBytes: Long = 0

    fun append(source: Buffer, byteCount: Long) {
        if (byteCount <= 0L) return
        totalBytes += byteCount
        if (maxBytes <= 0) return
        val remaining = maxBytes.toLong() - buffer.size
        if (remaining <= 0L) return
        val toCopy = minOf(byteCount, remaining)
        source.copyTo(buffer, 0, toCopy)
    }

    fun snapshot(contentType: MediaType?): RequestBodyCapture? {
        if (maxBytes <= 0) return null
        val captured = buffer.readByteArray()
        val truncatedBytes = (totalBytes - captured.size.toLong()).coerceAtLeast(0L)
        return RequestBodyCapture(
            contentType = contentType,
            body = captured,
            truncatedBytes = truncatedBytes,
        )
    }
}

private class CapturingRequestBody(
    private val delegate: okhttp3.RequestBody,
    private val maxBytes: Int,
) : okhttp3.RequestBody() {
    @Volatile
    private var captured: RequestBodyCapture? = null

    fun snapshot(): RequestBodyCapture? = captured

    override fun contentType(): MediaType? = delegate.contentType()

    override fun contentLength(): Long = delegate.contentLength()

    override fun isOneShot(): Boolean = delegate.isOneShot()

    override fun isDuplex(): Boolean = delegate.isDuplex()

    override fun writeTo(sink: BufferedSink) {
        val capture = RequestBodyCaptureBuffer(maxBytes)
        val capturingSink = object : ForwardingSink(sink) {
            override fun write(source: Buffer, byteCount: Long) {
                capture.append(source, byteCount)
                super.write(source, byteCount)
            }
        }
        val buffered = capturingSink.buffer()
        try {
            delegate.writeTo(buffered)
            buffered.flush()
        } finally {
            captured = capture.snapshot(contentType())
        }
    }
}

private class CompletionTrackingResponseBody(
    private val delegate: ResponseBody,
    private val onFinished: (Long?) -> Unit,
    private val onFailed: (Throwable) -> Unit,
) : ResponseBody() {
    private val closed = AtomicBoolean(false)
    private val completionNotified = AtomicBoolean(false)
    private var totalBytes: Long = 0L

    private val bufferedSource: BufferedSource by lazy {
        object : ForwardingSource(delegate.source()) {
            override fun read(sink: Buffer, byteCount: Long): Long {
                return runCatching {
                    val read = super.read(sink, byteCount)
                    if (read > 0L) {
                        totalBytes += read
                    } else if (read == -1L) {
                        completeSuccessfully()
                    }
                    read
                }.onFailure { error ->
                    completeWithError(error)
                }.getOrThrow()
            }

            override fun close() {
                val result = runCatching { super.close() }
                result.onFailure { error -> completeWithError(error) }
                if (result.isSuccess) {
                    completeSuccessfully()
                }
                result.getOrThrow()
            }
        }.buffer()
    }

    override fun contentType(): MediaType? = delegate.contentType()

    override fun contentLength(): Long = delegate.contentLength()

    override fun source(): BufferedSource = bufferedSource

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            bufferedSource.close()
        }
    }

    private fun completeSuccessfully() {
        if (!completionNotified.compareAndSet(false, true)) return
        val total = if (totalBytes > 0L) {
            totalBytes
        } else {
            delegate.safeContentLength()
        }
        onFinished(total)
    }

    private fun completeWithError(error: Throwable) {
        if (!completionNotified.compareAndSet(false, true)) return
        onFailed(error)
    }
}

private fun ResponseBody?.safeContentLength(): Long? = this?.let {
    try {
        it.contentLength().takeIf { len -> len >= 0L }
    } catch (_: IOException) {
        null
    }
}

private fun Response.hasNoBodyByProtocol(): Boolean {
    if (request.method.equals("HEAD", ignoreCase = true)) return true
    return code in 100..199 ||
        code == 204 ||
        code == 205 ||
        code == 304
}

private fun Response.bodyPreview(maxBytes: Int): String? {
    return if (maxBytes <= 0L) {
        null
    } else {
        try {
            val peek: ResponseBody = peekBody(maxBytes.toLong())
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

private fun MediaType?.isTextLike(): Boolean = when {
    this == null -> false
    type.lowercase() == "text" -> true
    else -> listOf(
        "json",
        "xml",
        "html",
        "javascript",
        "form",
        "graphql",
        "plain",
        "csv",
        "yaml",
    ).any(subtype.lowercase()::contains)
}

private fun MediaType?.isMultipartFormData(): Boolean {
    val mediaType = this ?: return false
    return mediaType.type.equals("multipart", ignoreCase = true) &&
        mediaType.subtype.equals("form-data", ignoreCase = true)
}

private fun MediaType?.isEventStream(): Boolean {
    val mediaType = this ?: return false
    return mediaType.type.equals("text", ignoreCase = true) &&
        mediaType.subtype.equals("event-stream", ignoreCase = true)
}

private fun Response.captureTextBody(maxBytes: Int, previewBytes: Int): TextBodyCapture? {
    val responseBody = body
    val mediaType = responseBody.contentType()
    val isKnownText = mediaType?.isTextLike() == true
    return when {
        maxBytes <= 0L -> null
        mediaType != null && !isKnownText -> null
        else -> try {
            val contentLength = responseBody.contentLength()
            val effectiveMax = when {
                contentLength in 0 until AbsoluteBodyTextMaxBytes -> max(maxBytes, contentLength.toInt())
                else -> maxBytes
            }
            val peek = peekBody(effectiveMax.toLong() + 1L)
            val bytes = peek.bytes()
            val truncated = bytes.size > effectiveMax
            val effective = if (truncated) bytes.copyOf(effectiveMax) else bytes
            val charset = mediaType.resolveCharset()
            val text = if (isKnownText) {
                String(effective, charset)
            } else {
                effective.decodeUtf8TextIfLikely() ?: return null
            }
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

private fun Response.captureBinaryBody(maxBytes: Int, previewBytes: Int): BinaryBodyCapture? {
    val responseBody = body
    val mediaType = responseBody.contentType()
    return when {
        maxBytes <= 0L -> null
        mediaType?.isTextLike() == true -> null
        mediaType.isEventStream() -> null
        else -> try {
            val contentLength = responseBody.contentLength()
            val effectiveMax = when {
                contentLength in 0 until AbsoluteBodyTextMaxBytes ->
                    max(maxBytes, contentLength.toInt())
                else -> maxBytes
            }
            val peek = peekBody(effectiveMax.toLong() + 1L)
            val bytes = peek.bytes()
            val truncated = bytes.size > effectiveMax
            val effective = if (truncated) bytes.copyOf(effectiveMax) else bytes
            val previewLimit = previewBytes.coerceAtMost(effective.size)
            val preview = if (previewLimit > 0) {
                encodeToString(effective, 0, previewLimit, NO_WRAP)
            } else {
                null
            }
            BinaryBodyCapture(
                base64 = encodeToString(effective, NO_WRAP),
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

private fun hasNonIdentityContentEncoding(contentEncoding: String?): Boolean {
    val encodings = contentEncoding
        ?.split(',')
        ?.map { token -> token.substringBefore(';').trim().lowercase() }
        ?.filter { token -> token.isNotEmpty() }
        .orEmpty()
    return encodings.any { token -> token != "identity" }
}

private fun TextBodyCapture.truncatedBytes(totalBytes: Long?): Long? {
    return when {
        totalBytes != null -> max(totalBytes - capturedBytes, 0L)
        truncated -> max(originalBytes - capturedBytes, 0L)
        else -> null
    }
}

private fun BinaryBodyCapture.truncatedBytes(totalBytes: Long?): Long? {
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

private fun resolveRequestContentType(
    captureContentType: MediaType?,
    request: Request,
): MediaType? {
    if (captureContentType != null) return captureContentType
    val headerValue = request.header("Content-Type") ?: return null
    return headerValue.toMediaTypeOrNull()
}

private fun ByteArray.decodeUtf8TextIfLikely(): String? {
    if (isEmpty()) return ""
    val decoded = runCatching {
        Charsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(this))
            .toString()
    }.getOrNull() ?: return null
    if (decoded.isEmpty()) return decoded
    val printable = decoded.count { ch ->
        ch == '\n' || ch == '\r' || ch == '\t' || (ch >= ' ' && ch != '\u007f')
    }
    val printableRatio = printable.toDouble() / decoded.length.toDouble()
    return decoded.takeIf { printableRatio >= MinLikelyTextRatio }
}

private fun formatMultipartBody(bodyBytes: ByteArray, contentType: MediaType?): String {
    val boundary = extractMultipartBoundary(contentType) ?: return String(bodyBytes, Charsets.UTF_8)
    val sections = splitMultipartSections(bodyBytes, boundary)
    val parts = sections.mapNotNull(::parseMultipartSection)
    if (parts.isEmpty()) return String(bodyBytes, Charsets.UTF_8)
    return renderMultipartParts(parts)
}

private fun extractMultipartBoundary(contentType: MediaType?): String? {
    val boundary = contentType?.parameter("boundary")?.trim()?.trim('"') ?: return null
    return boundary.takeIf { it.isNotEmpty() }
}

private data class MultipartPart(
    val name: String?,
    val filename: String?,
    val contentType: String?,
    val bodyBytes: ByteArray,
    val isText: Boolean,
    val charset: Charset?,
)

private fun parseMultipartSection(sectionBytes: ByteArray): MultipartPart? {
    val trimmed = sectionBytes.trimMultipartSection() ?: return null
    val (headerBytes, bodyBytes) = splitMultipartBytes(trimmed)
    val headers = parseMultipartHeaders(headerBytes)
    val disposition = headers["content-disposition"]
    val name = disposition?.let { parseHeaderParam(it, "name") }
    val filename = disposition?.let { parseHeaderParam(it, "filename") }
    val partType = headers["content-type"]
    val isText = isTextMultipartPart(partType, filename)
    val charset = parseCharset(partType)

    return MultipartPart(
        name = name,
        filename = filename,
        contentType = partType,
        bodyBytes = bodyBytes,
        isText = isText,
        charset = charset,
    )
}

private fun splitMultipartSections(bodyBytes: ByteArray, boundary: String): List<ByteArray> {
    val marker = ("--$boundary").toByteArray(Charsets.UTF_8)
    val indices = findAllMarkers(bodyBytes, marker)
    if (indices.isEmpty()) return emptyList()
    val sections = ArrayList<ByteArray>(indices.size)
    for (index in indices.indices) {
        val markerIndex = indices[index]
        if (startsWith(bodyBytes, markerIndex + marker.size, byteArrayOf('-'.code.toByte(), '-'.code.toByte()))) {
            break
        }
        val sectionStart = skipLineBreaks(bodyBytes, markerIndex + marker.size)
        val sectionEnd = resolveSectionEnd(bodyBytes, indices, index)
        if (sectionStart < sectionEnd) {
            sections.add(bodyBytes.copyOfRange(sectionStart, sectionEnd))
        }
    }
    return sections
}

private fun resolveSectionEnd(
    bodyBytes: ByteArray,
    indices: List<Int>,
    index: Int,
): Int {
    val nextIndex = indices.getOrNull(index + 1) ?: bodyBytes.size
    var end = nextIndex
    if (end >= 2 && bodyBytes[end - 2] == '\r'.code.toByte() && bodyBytes[end - 1] == '\n'.code.toByte()) {
        end -= 2
    }
    return end
}

private fun findAllMarkers(source: ByteArray, marker: ByteArray): List<Int> {
    val indices = ArrayList<Int>()
    var index = indexOfSequence(source, marker, 0)
    while (index >= 0) {
        indices.add(index)
        index = indexOfSequence(source, marker, index + marker.size)
    }
    return indices
}

private fun indexOfSequence(source: ByteArray, pattern: ByteArray, startIndex: Int): Int {
    if (pattern.isEmpty() || source.size < pattern.size) return -1
    val maxIndex = source.size - pattern.size
    var index = startIndex.coerceAtLeast(0)
    while (index <= maxIndex) {
        if (matchesAt(source, pattern, index)) return index
        index++
    }
    return -1
}

private fun matchesAt(source: ByteArray, pattern: ByteArray, index: Int): Boolean {
    for (offset in pattern.indices) {
        if (source[index + offset] != pattern[offset]) return false
    }
    return true
}

private fun skipLineBreaks(source: ByteArray, startIndex: Int): Int {
    var index = startIndex
    if (startsWith(source, index, byteArrayOf('\r'.code.toByte(), '\n'.code.toByte()))) {
        index += 2
    } else if (startsWith(source, index, byteArrayOf('\n'.code.toByte()))) {
        index += 1
    }
    return index
}

private fun startsWith(source: ByteArray, startIndex: Int, prefix: ByteArray): Boolean {
    if (startIndex < 0 || startIndex + prefix.size > source.size) return false
    for (i in prefix.indices) {
        if (source[startIndex + i] != prefix[i]) return false
    }
    return true
}

private fun splitMultipartBytes(section: ByteArray): Pair<ByteArray, ByteArray> {
    val crlfcrlf = byteArrayOf(
        '\r'.code.toByte(),
        '\n'.code.toByte(),
        '\r'.code.toByte(),
        '\n'.code.toByte(),
    )
    val lfLf = byteArrayOf('\n'.code.toByte(), '\n'.code.toByte())
    val crlfIndex = indexOfSequence(section, crlfcrlf, 0)
    if (crlfIndex >= 0) {
        return section.copyOfRange(0, crlfIndex) to section.copyOfRange(crlfIndex + crlfcrlf.size, section.size)
    }
    val lfIndex = indexOfSequence(section, lfLf, 0)
    if (lfIndex >= 0) {
        return section.copyOfRange(0, lfIndex) to section.copyOfRange(lfIndex + lfLf.size, section.size)
    }
    return section to ByteArray(0)
}

private fun renderMultipartParts(parts: List<MultipartPart>): String {
    val rendered = StringBuilder()
    parts.forEach { part ->
        rendered.append("Part")
        if (part.name != null) rendered.append(" name=\"").append(part.name).append("\"")
        if (part.filename != null) rendered.append(" filename=\"").append(part.filename).append("\"")
        if (part.contentType != null) rendered.append(" (").append(part.contentType).append(")")
        rendered.append("\n")

        if (part.isText) {
            rendered.append(String(part.bodyBytes, part.charset ?: Charsets.UTF_8))
        } else {
            rendered.append(encodeToString(part.bodyBytes, NO_WRAP))
        }
        rendered.append("\n\n")
    }
    return rendered.toString().trimEnd()
}

private fun parseMultipartHeaders(headerBytes: ByteArray): Map<String, String> {
    if (headerBytes.isEmpty()) return emptyMap()
    return parseMultipartHeaders(headerBytes.toString(Charsets.ISO_8859_1))
}

private fun parseMultipartHeaders(headerBlock: String): Map<String, String> {
    if (headerBlock.isBlank()) return emptyMap()
    return headerBlock
        .lines()
        .mapNotNull { line ->
            val idx = line.indexOf(':')
            if (idx <= 0) return@mapNotNull null
            val key = line.substring(0, idx).trim().lowercase()
            val value = line.substring(idx + 1).trim()
            key to value
        }
        .toMap()
}

private fun ByteArray.trimMultipartSection(): ByteArray? {
    if (isEmpty()) return null
    var start = 0
    var end = size
    while (start < end && this[start].toInt() == '\n'.code) start++
    while (start < end && this[start].toInt() == '\r'.code) start++
    while (end > start && this[end - 1].toInt() == '\n'.code) end--
    while (end > start && this[end - 1].toInt() == '\r'.code) end--
    if (start >= end) return null
    return copyOfRange(start, end)
}

private fun isTextMultipartPart(contentType: String?, filename: String?): Boolean {
    return when {
        contentType != null -> contentType.isTextLikeHeader()
        filename != null -> false
        else -> true
    }
}

private fun parseCharset(contentType: String?): Charset? {
    val value = contentType ?: return null
    val charset = value.split(';')
        .firstOrNull { it.trim().startsWith("charset=", ignoreCase = true) }
        ?.substringAfter('=')
        ?.trim()
        ?.trim('"')
        ?.takeIf { it.isNotEmpty() }
        ?: return null
    return try {
        Charset.forName(charset)
    } catch (_: IllegalArgumentException) {
        null
    }
}

private fun parseHeaderParam(headerValue: String, paramName: String): String? {
    return headerValue
        .split(';')
        .asSequence()
        .map { it.trim() }
        .mapNotNull { segment ->
            val idx = segment.indexOf('=')
            if (idx <= 0) return@mapNotNull null
            val key = segment.substring(0, idx).trim()
            val value = segment.substring(idx + 1).trim().trim('"')
            key to value
        }
        .firstOrNull { (key, _) -> key.equals(paramName, ignoreCase = true) }
        ?.second
}

private fun String.isTextLikeHeader(): Boolean {
    val value = lowercase()
    return value.startsWith("text/") ||
        listOf(
            "application/json",
            "application/xml",
            "application/x-www-form-urlencoded",
            "application/graphql",
            "application/javascript",
        ).any { value.contains(it) } ||
        listOf("json", "xml", "html", "javascript", "form", "graphql", "plain", "csv", "yaml")
            .any { value.contains(it) }
}

internal fun nanosToMillis(deltaNs: Long): Long? {
    if (deltaNs <= 0L) return null
    return TimeUnit.NANOSECONDS.toMillis(deltaNs)
}

private const val MinLikelyTextRatio: Double = 0.85
private const val AbsoluteBodyTextMaxBytes: Long = 8L * 1024L * 1024L

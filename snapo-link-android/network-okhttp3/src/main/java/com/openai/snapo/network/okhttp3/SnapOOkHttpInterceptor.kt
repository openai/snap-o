package com.openai.snapo.network.okhttp3

import android.os.SystemClock
import android.util.Base64.NO_WRAP
import android.util.Base64.encodeToString
import com.openai.snapo.network.NetworkInspector
import com.openai.snapo.network.capture.BodyContentType
import com.openai.snapo.network.capture.CaptureEventPublisher
import com.openai.snapo.network.capture.RawResponseBodyCapture
import com.openai.snapo.network.capture.ResolvedRequestBody
import com.openai.snapo.network.capture.resolveEffectiveMaxBytes
import com.openai.snapo.network.capture.resolveRequestBody
import com.openai.snapo.network.capture.resolveResponseCaptureLimit
import com.openai.snapo.network.capture.shouldEncodeBodyAsBase64
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.TrailersSource
import okio.Buffer
import okio.BufferedSink
import okio.BufferedSource
import okio.ForwardingSink
import okio.ForwardingSource
import okio.buffer
import java.io.Closeable
import java.io.IOException
import java.nio.charset.Charset
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import com.openai.snapo.network.capture.resolveRequestCaptureLimit as resolveSharedRequestCaptureLimit

/** OkHttp interceptor that mirrors traffic to the active SnapO link if present. */
class SnapOOkHttpInterceptor @JvmOverloads constructor(
    responseBodyPreviewBytes: Int = DefaultBodyPreviewBytes,
    textBodyMaxBytes: Int = DefaultTextBodyMaxBytes,
    binaryBodyMaxBytes: Int = DefaultBinaryBodyMaxBytes,
    dispatcher: CoroutineDispatcher = DefaultDispatcher,
) : Interceptor, Closeable {

    private val responseBodyPreviewBytes = responseBodyPreviewBytes.coerceAtLeast(0)
    private val textBodyMaxBytes = resolveEffectiveMaxBytes(textBodyMaxBytes, contentLength = null)
    private val binaryBodyMaxBytes = resolveEffectiveMaxBytes(binaryBodyMaxBytes, contentLength = null)
    private val publisher = CaptureEventPublisher(
        responseBodyPreviewBytes = this.responseBodyPreviewBytes,
        textBodyMaxBytes = this.textBodyMaxBytes,
        binaryBodyMaxBytes = this.binaryBodyMaxBytes,
        dispatcher = dispatcher,
    )

    @Suppress("TooGenericExceptionCaught")
    override fun intercept(chain: Interceptor.Chain): Response {
        if (NetworkInspector.getOrNull() == null) {
            return chain.proceed(chain.request())
        }

        val context = InterceptContext(
            requestId = UUID.randomUUID().toString(),
            startWall = System.currentTimeMillis(),
            startMono = SystemClock.elapsedRealtimeNanos(),
        )

        val request = chain.request()
        val requestBody = request.body
        val declaredRequestBodySize = requestBody.safeContentLength()
        val requestPublication = publisher.publish {
            OkhttpEventFactory.createRequestWillBeSent(
                context,
                request,
                hasBody = requestBody != null,
                body = null,
                bodyEncoding = requestBodyEncoding(request),
                truncatedBytes = null,
                bodySize = declaredRequestBodySize,
            )
        }
        val requestCapture = RequestCaptureTracker(requestPublication) { capture, after ->
            publisher.updateRequestBody(
                requestId = context.requestId,
                bodyValues = { encodeRequestBody(capture, request) },
                bodyTruncatedBytes = capture.truncatedBytes,
                bodySize = maxOf(declaredRequestBodySize ?: 0L, capture.totalBytes),
                after = after,
            )
        }
        val interceptedRequest = request.withCapturingBody(
            maxBytes = resolveRequestCaptureLimit(
                request = request,
                textBodyMaxBytes = textBodyMaxBytes,
                binaryBodyMaxBytes = binaryBodyMaxBytes,
            ),
            onComplete = requestCapture::captured,
        )

        return try {
            val response = chain.proceed(interceptedRequest)
            handleResponse(context, response, after = requestCapture.completion())
        } catch (error: IOException) {
            rethrowAfterRequestFailure(context, requestCapture.completion(), error)
        } catch (error: RuntimeException) {
            rethrowAfterRequestFailure(context, requestCapture.completion(), error)
        }
    }

    private fun rethrowAfterRequestFailure(
        context: InterceptContext,
        requestCompletion: Job?,
        error: Throwable,
    ): Nothing {
        publisher.publishFailure(
            requestId = context.requestId,
            requestStartMono = context.startMono,
            error = error,
            after = requestCompletion,
        )
        throw error
    }

    override fun close() {
        publisher.close()
    }

    private fun handleResponse(context: InterceptContext, response: Response, after: Job?): Response {
        val endWall = System.currentTimeMillis()
        val endMono = SystemClock.elapsedRealtimeNanos()
        val responseBody = response.body
        val bodySize = responseBody.safeContentLength()
        if (response.hasNoBodyByProtocol()) {
            val responsePublication = publishResponseMetadata(
                context,
                response,
                bodySize,
                endWall = endWall,
                endMono = endMono,
                after = after,
            )
            publisher.publishFinished(context.requestId, bodySize = 0L, after = responsePublication)
            return response
        }
        val contentType = responseBody.contentType().toBodyContentType()
        return if (contentType?.isEventStream == true) {
            handleStreamingResponse(
                context,
                response,
                responseBody,
                contentType = contentType,
                bodySize = bodySize,
                endWall = endWall,
                endMono = endMono,
                after = after,
            )
        } else {
            handleStandardResponse(
                context = context,
                response = response,
                body = responseBody,
                contentType = contentType,
                bodySize = bodySize,
                endWall = endWall,
                endMono = endMono,
                after = after,
            )
        }
    }

    private fun handleStandardResponse(
        context: InterceptContext,
        response: Response,
        body: ResponseBody,
        contentType: BodyContentType?,
        bodySize: Long?,
        endWall: Long,
        endMono: Long,
        after: Job?,
    ): Response {
        val responsePublication = publishResponseMetadata(
            context = context,
            response = response,
            bodySize = bodySize,
            endWall = endWall,
            endMono = endMono,
            after = after,
        )
        if (bodySize == 0L) {
            publisher.publishFinished(context.requestId, bodySize = 0L, after = responsePublication)
            return response
        }
        val capturingBody = CapturingResponseBody(
            delegate = body,
            maxBytes = resolveResponseCaptureLimit(
                contentType = contentType,
                contentLength = bodySize,
                textBodyMaxBytes = textBodyMaxBytes,
                binaryBodyMaxBytes = binaryBodyMaxBytes,
                previewBytes = responseBodyPreviewBytes,
            ),
            onComplete = { capture, error ->
                publisher.completeResponse(
                    requestId = context.requestId,
                    requestStartMono = context.startMono,
                    capture = capture,
                    contentType = contentType,
                    declaredBodySize = bodySize,
                    error = error,
                    after = responsePublication,
                )
            },
        )
        return response.newBuilder()
            .body(capturingBody)
            .trailers(capturingTrailersSource(response, capturingBody))
            .build()
    }

    private fun handleStreamingResponse(
        context: InterceptContext,
        response: Response,
        body: ResponseBody,
        contentType: BodyContentType?,
        bodySize: Long?,
        endWall: Long,
        endMono: Long,
        after: Job?,
    ): Response {
        val responsePublication = publishResponseMetadata(context, response, bodySize, endWall, endMono, after)
        val publicationLock = Any()
        var previousPublication = responsePublication
        val streamingBody = StreamingResponseRelayBody(
            delegate = body,
            requestId = context.requestId,
            charset = contentType?.charsetOrUtf8() ?: Charsets.UTF_8,
            onRecord = { recordBuilder ->
                synchronized(publicationLock) {
                    previousPublication = publisher.publish(
                        after = previousPublication,
                        builder = recordBuilder,
                    ) ?: previousPublication
                }
            },
        )
        return response.newBuilder().body(streamingBody).build()
    }

    private fun publishResponseMetadata(
        context: InterceptContext,
        response: Response,
        bodySize: Long?,
        endWall: Long,
        endMono: Long,
        after: Job?,
    ): Job? {
        return publisher.publish(after = after) {
            OkhttpEventFactory.createResponseReceived(
                context = context,
                response = response,
                endWall = endWall,
                endMono = endMono,
                bodyPreview = null,
                bodyText = null,
                bodyEncoding = null,
                truncatedBytes = null,
                bodySize = bodySize,
            )
        }
    }
}

internal data class InterceptContext(
    val requestId: String,
    val startWall: Long,
    val startMono: Long,
)

internal data class RequestBodyCapture(
    val contentType: MediaType?,
    val body: ByteArray,
    val totalBytes: Long,
    val truncatedBytes: Long,
)

private class RequestCaptureTracker(
    initialCompletion: Job?,
    private val update: (RequestBodyCapture, Job?) -> Job?,
) {
    private val lock = Any()
    private var latestCompletion = initialCompletion

    fun captured(capture: RequestBodyCapture) {
        synchronized(lock) {
            latestCompletion = update(capture, latestCompletion) ?: latestCompletion
        }
    }

    fun completion(): Job? = synchronized(lock) { latestCompletion }
}

private fun Request.withCapturingBody(
    maxBytes: Int,
    onComplete: (RequestBodyCapture) -> Unit,
): Request {
    val requestBody = body ?: return this
    if (requestBody.isDuplex() || maxBytes <= 0) return this
    return newBuilder()
        .method(
            method,
            CapturingRequestBody(
                delegate = requestBody,
                maxBytes = maxBytes,
                onComplete = onComplete,
            ),
        )
        .build()
}

private data class CapturedBytes(
    val body: ByteArray,
    val totalBytes: Long,
)

private class BodyCaptureBuffer(private val maxBytes: Int) {
    private val buffer = Buffer()
    private var totalBytes: Long = 0

    fun append(source: Buffer, offset: Long, byteCount: Long) {
        if (byteCount <= 0L) return
        totalBytes += byteCount
        if (maxBytes <= 0) return
        val remaining = maxBytes.toLong() - buffer.size
        if (remaining <= 0L) return
        val toCopy = minOf(byteCount, remaining)
        source.copyTo(buffer, offset, toCopy)
    }

    fun snapshot(): CapturedBytes = CapturedBytes(
        body = buffer.readByteArray(),
        totalBytes = totalBytes,
    )
}

internal class CapturingRequestBody(
    private val delegate: okhttp3.RequestBody,
    private val maxBytes: Int,
    private val onComplete: (RequestBodyCapture) -> Unit,
) : okhttp3.RequestBody() {
    override fun contentType(): MediaType? = delegate.contentType()

    override fun contentLength(): Long = delegate.contentLength()

    override fun isOneShot(): Boolean = delegate.isOneShot()

    override fun isDuplex(): Boolean = delegate.isDuplex()

    override fun writeTo(sink: BufferedSink) {
        val capture = BodyCaptureBuffer(maxBytes)
        val capturingSink = object : ForwardingSink(sink) {
            override fun write(source: Buffer, byteCount: Long) {
                capture.append(source, offset = 0L, byteCount = byteCount)
                super.write(source, byteCount)
            }
        }
        val buffered = capturingSink.buffer()
        try {
            delegate.writeTo(buffered)
            buffered.emit()
        } finally {
            val snapshot = capture.snapshot()
            val completedCapture = RequestBodyCapture(
                contentType = runCatching { contentType() }.getOrNull(),
                body = snapshot.body,
                totalBytes = snapshot.totalBytes,
                truncatedBytes = (snapshot.totalBytes - snapshot.body.size.toLong()).coerceAtLeast(0L),
            )
            try {
                onComplete(completedCapture)
            } catch (_: Throwable) {
            }
        }
    }
}

internal class CapturingResponseBody(
    private val delegate: ResponseBody,
    maxBytes: Int,
    private val onComplete: (RawResponseBodyCapture, Throwable?) -> Unit,
) : ResponseBody() {
    private val closed = AtomicBoolean(false)
    private val completionNotified = AtomicBoolean(false)
    private val capture = BodyCaptureBuffer(maxBytes)

    private val bufferedSource: BufferedSource by lazy {
        object : ForwardingSource(delegate.source()) {
            override fun read(sink: Buffer, byteCount: Long): Long {
                return runCatching {
                    val read = super.read(sink, byteCount)
                    if (read > 0L) {
                        capture.append(sink, offset = sink.size - read, byteCount = read)
                    } else if (read == -1L) {
                        complete(error = null, reachedEof = true)
                    }
                    read
                }.onFailure { error ->
                    complete(error = error, reachedEof = false)
                }.getOrThrow()
            }

            override fun close() {
                val result = runCatching { super.close() }
                complete(error = result.exceptionOrNull(), reachedEof = false)
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

    private fun complete(error: Throwable?, reachedEof: Boolean) {
        if (!completionNotified.compareAndSet(false, true)) return
        val snapshot = capture.snapshot()
        try {
            onComplete(
                RawResponseBodyCapture(
                    bytes = snapshot.body,
                    totalBytes = snapshot.totalBytes,
                    reachedEof = reachedEof,
                ),
                error,
            )
        } catch (_: Throwable) {
        }
    }
}

internal fun capturingTrailersSource(response: Response, body: ResponseBody): TrailersSource {
    return object : TrailersSource {
        override fun peek(): Headers? = response.peekTrailers()

        override fun get(): Headers {
            val source = body.source()
            val discard = Buffer()
            while (source.read(discard, SegmentByteCount) != -1L) {
                discard.clear()
            }
            return response.trailers()
        }
    }
}

private fun ResponseBody?.safeContentLength(): Long? = this?.let {
    try {
        it.contentLength().takeIf { len -> len >= 0L }
    } catch (_: IOException) {
        null
    }
}

private fun okhttp3.RequestBody?.safeContentLength(): Long? = this?.let {
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

internal fun resolveRequestCaptureLimit(
    request: Request,
    textBodyMaxBytes: Int,
    binaryBodyMaxBytes: Int,
): Int {
    val requestBody = request.body ?: return 0
    val contentType = resolveRequestContentType(
        captureContentType = runCatching { requestBody.contentType() }.getOrNull(),
        request = request,
    ).toBodyContentType()
    return resolveSharedRequestCaptureLimit(
        contentType = contentType,
        contentEncoding = request.header("Content-Encoding"),
        textBodyMaxBytes = textBodyMaxBytes,
        binaryBodyMaxBytes = binaryBodyMaxBytes,
    )
}

private fun requestBodyEncoding(request: Request): String? {
    val requestBody = request.body ?: return null
    val contentType = resolveRequestContentType(
        captureContentType = runCatching { requestBody.contentType() }.getOrNull(),
        request = request,
    ).toBodyContentType()
    return "base64".takeIf {
        shouldEncodeBodyAsBase64(
            contentType = contentType,
            contentEncoding = request.header("Content-Encoding"),
        )
    }
}

private fun encodeRequestBody(capture: RequestBodyCapture, request: Request): ResolvedRequestBody {
    val mediaType = resolveRequestContentType(capture.contentType, request)
    val contentType = mediaType.toBodyContentType()
    return if (
        contentType?.isMultipartFormData == true &&
        !shouldEncodeBodyAsBase64(
            contentType = contentType,
            contentEncoding = request.header("Content-Encoding"),
        )
    ) {
        ResolvedRequestBody(body = formatMultipartBody(capture.body, mediaType), encoding = null)
    } else {
        resolveRequestBody(
            bytes = capture.body,
            contentType = contentType,
            contentEncoding = request.header("Content-Encoding"),
        )
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

private fun MediaType?.toBodyContentType(): BodyContentType? {
    val mediaType = this ?: return null
    val charset = runCatching { mediaType.charset() }.getOrNull()
    return BodyContentType(
        type = mediaType.type,
        subtype = mediaType.subtype,
        charset = charset,
    )
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

private const val SegmentByteCount: Long = 8L * 1024L

package com.openai.snapo.network.okhttp3

import android.os.SystemClock
import android.util.Base64.NO_WRAP
import android.util.Base64.encodeToString
import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.NetworkInspector
import com.openai.snapo.network.RequestFailed
import com.openai.snapo.network.ResponseFinished
import com.openai.snapo.network.Timings
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
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
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.io.encoding.Base64

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
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

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
        val requestPublication = publishRequest(context, request, declaredRequestBodySize)
        val requestCapture = RequestCaptureTracker(requestPublication) { capture, after ->
            updateRequestBody(
                context = context,
                after = after,
                request = request,
                declaredBodySize = declaredRequestBodySize,
                capture = capture,
            )
        }
        val interceptedRequest = request.withCapturingBody(
            maxBytes = requestCaptureLimit(request),
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
        handleFailure(context, error, after = requestCompletion)
        throw error
    }

    override fun close() {
        scope.cancel()
    }

    private fun publishRequest(
        context: InterceptContext,
        request: Request,
        declaredBodySize: Long?,
    ): Job? = publish {
        OkhttpEventFactory.createRequestWillBeSent(
            context,
            request,
            hasBody = request.body != null,
            body = null,
            bodyEncoding = requestBodyEncoding(request),
            truncatedBytes = null,
            bodySize = declaredBodySize,
        )
    }

    private fun updateRequestBody(
        context: InterceptContext,
        after: Job?,
        request: Request,
        declaredBodySize: Long?,
        capture: RequestBodyCapture?,
    ): Job? {
        if (capture == null) return after
        val server = NetworkInspector.getOrNull() ?: return null
        return scope.launch {
            try {
                after?.join()
                val encoded = encodeRequestBody(capture, request)
                server.updateLatestRequestBody(
                    requestId = context.requestId,
                    body = encoded.body,
                    bodyEncoding = encoded.encoding,
                    bodyTruncatedBytes = capture.truncatedBytes,
                    bodySize = maxOf(declaredBodySize ?: 0L, capture.totalBytes),
                )
            } catch (_: Throwable) {
            }
        }
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
            publishLoadingFinished(context, bodySize = 0L, after = responsePublication)
            return response
        }
        val contentType = responseBody.contentType()
        return if (contentType.isEventStream()) {
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
        contentType: MediaType?,
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
            publishLoadingFinished(context, bodySize = 0L, after = responsePublication)
            return response
        }
        val capturingBody = CapturingResponseBody(
            delegate = body,
            maxBytes = responseCaptureLimit(contentType, bodySize),
            onComplete = { capture, error ->
                completeResponseCapture(
                    context = context,
                    contentType = contentType,
                    declaredBodySize = bodySize,
                    responsePublication = responsePublication,
                    capture = capture,
                    error = error,
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
        contentType: MediaType?,
        bodySize: Long?,
        endWall: Long,
        endMono: Long,
        after: Job?,
    ): Response {
        val responsePublication = publish(after = after) {
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
        val publicationLock = Any()
        var previousPublication = responsePublication
        val streamingBody = StreamingResponseRelayBody(
            delegate = body,
            requestId = context.requestId,
            charset = contentType.resolveCharset(),
            onRecord = { recordBuilder ->
                synchronized(publicationLock) {
                    previousPublication = publish(
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
        return publish(after = after) {
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

    private fun requestCaptureLimit(request: Request): Int {
        return resolveRequestCaptureLimit(
            request = request,
            textBodyMaxBytes = textBodyMaxBytes,
            binaryBodyMaxBytes = binaryBodyMaxBytes,
        )
    }

    private fun responseCaptureLimit(contentType: MediaType?, contentLength: Long?): Int {
        val bodyLimit = when {
            contentType == null -> maxOf(textBodyMaxBytes, binaryBodyMaxBytes)
            contentType.isTextLike() -> textBodyMaxBytes
            else -> binaryBodyMaxBytes
        }
        return resolveEffectiveMaxBytes(
            maxBytes = maxOf(bodyLimit, responseBodyPreviewBytes),
            contentLength = contentLength,
        )
    }

    private fun completeResponseCapture(
        context: InterceptContext,
        contentType: MediaType?,
        declaredBodySize: Long?,
        responsePublication: Job?,
        capture: ResponseBodyCapture,
        error: Throwable?,
    ) {
        val completionWall = System.currentTimeMillis()
        val completionMono = SystemClock.elapsedRealtimeNanos()
        val server = NetworkInspector.getOrNull() ?: return
        scope.launch {
            try {
                responsePublication?.join()
                val body = runCatching {
                    resolveResponseBodyCapture(
                        capture = capture,
                        contentType = contentType,
                        textBodyMaxBytes = textBodyMaxBytes,
                        binaryBodyMaxBytes = binaryBodyMaxBytes,
                        previewBytes = responseBodyPreviewBytes,
                        declaredBodySize = declaredBodySize,
                    )
                }.getOrNull()
                if (body != null) {
                    runCatching {
                        server.updateLatestResponseBody(
                            requestId = context.requestId,
                            bodyPreview = body.preview,
                            body = body.body,
                            bodyEncoding = body.encoding,
                            bodyTruncatedBytes = body.truncatedBytes,
                            bodySize = body.bodySize,
                        )
                    }
                }
                val completedBodySize = body?.bodySize
                    ?: declaredBodySize
                    ?: capture.totalBytes
                val completionRecord = if (error == null) {
                    ResponseFinished(
                        id = context.requestId,
                        tWallMs = completionWall,
                        tMonoNs = completionMono,
                        bodySize = completedBodySize,
                        bodyTruncatedBytes = body?.truncatedBytes,
                    )
                } else {
                    RequestFailed(
                        id = context.requestId,
                        tWallMs = completionWall,
                        tMonoNs = completionMono,
                        errorKind = error.javaClass.simpleName.ifEmpty { error.javaClass.name },
                        message = error.message,
                        timings = Timings(totalMs = nanosToMillis(completionMono - context.startMono)),
                    )
                }
                server.publish(completionRecord)
            } catch (_: Throwable) {
            }
        }
    }

    private fun handleFailure(context: InterceptContext, error: Throwable, after: Job? = null) {
        val failWall = System.currentTimeMillis()
        val failMono = SystemClock.elapsedRealtimeNanos()
        publish(after = after) {
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

    private fun publishLoadingFinished(context: InterceptContext, bodySize: Long?, after: Job? = null) {
        val finishWall = System.currentTimeMillis()
        val finishMono = SystemClock.elapsedRealtimeNanos()
        publish(after = after) {
            ResponseFinished(
                id = context.requestId,
                tWallMs = finishWall,
                tMonoNs = finishMono,
                bodySize = bodySize,
            )
        }
    }

    private inline fun publish(
        after: Job? = null,
        crossinline builder: () -> NetworkEventRecord,
    ): Job? {
        val server = NetworkInspector.getOrNull() ?: return null
        return scope.launch {
            try {
                after?.join()
                server.publish(builder())
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

internal data class RequestBodyCapture(
    val contentType: MediaType?,
    val body: ByteArray,
    val totalBytes: Long,
    val truncatedBytes: Long,
)

internal data class ResponseBodyCapture(
    val body: ByteArray,
    val totalBytes: Long,
    val reachedEof: Boolean,
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
    private val onComplete: (ResponseBodyCapture, Throwable?) -> Unit,
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
                ResponseBodyCapture(
                    body = snapshot.body,
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

private data class EncodedBody(
    val body: String?,
    val encoding: String?,
)

internal fun resolveRequestCaptureLimit(
    request: Request,
    textBodyMaxBytes: Int,
    binaryBodyMaxBytes: Int,
): Int {
    val requestBody = request.body ?: return 0
    val contentType = resolveRequestContentType(
        captureContentType = runCatching { requestBody.contentType() }.getOrNull(),
        request = request,
    )
    return if (requestBodyUsesBase64(request, contentType)) {
        binaryBodyMaxBytes
    } else {
        textBodyMaxBytes
    }
}

private fun requestBodyEncoding(request: Request): String? {
    val requestBody = request.body ?: return null
    val contentType = resolveRequestContentType(
        captureContentType = runCatching { requestBody.contentType() }.getOrNull(),
        request = request,
    )
    return "base64".takeIf { requestBodyUsesBase64(request, contentType) }
}

private fun encodeRequestBody(capture: RequestBodyCapture, request: Request): EncodedBody {
    val contentType = resolveRequestContentType(capture.contentType, request)
    return when {
        requestBodyUsesBase64(request, contentType) ->
            EncodedBody(encodeToString(capture.body, NO_WRAP), "base64")

        contentType.isMultipartFormData() ->
            EncodedBody(formatMultipartBody(capture.body, contentType), null)

        else -> EncodedBody(String(capture.body, contentType.resolveCharset()), null)
    }
}

private fun requestBodyUsesBase64(request: Request, contentType: MediaType?): Boolean {
    return hasNonIdentityContentEncoding(request.header("Content-Encoding")) ||
        (!contentType.isTextLike() && !contentType.isMultipartFormData())
}

internal data class ResolvedResponseBodyCapture(
    val preview: String?,
    val body: String?,
    val encoding: String?,
    val truncatedBytes: Long?,
    val bodySize: Long,
)

internal fun resolveResponseBodyCapture(
    capture: ResponseBodyCapture,
    contentType: MediaType?,
    textBodyMaxBytes: Int,
    binaryBodyMaxBytes: Int,
    previewBytes: Int,
    declaredBodySize: Long?,
): ResolvedResponseBodyCapture {
    val likelyText = capture.isLikelyText(contentType)
    val bodyLimit = resolveEffectiveMaxBytes(
        maxBytes = if (likelyText) textBodyMaxBytes else binaryBodyMaxBytes,
        contentLength = declaredBodySize,
    )
    val retainedBodyBytes = capture.body.prefix(bodyLimit)
    val previewSource = capture.body.prefix(previewBytes)
    val charset = contentType.resolveCharset()
    val body = retainedBodyBytes.encodeForInspector(likelyText, charset)
    val preview = previewSource.encodeForInspector(likelyText, charset)
    val bodySize = capture.resolvedBodySize(declaredBodySize)
    val truncatedBytes = capture.resolvedTruncatedBytes(
        bodySize = bodySize,
        retainedBytes = retainedBodyBytes.size,
        hasDeclaredBodySize = declaredBodySize != null,
    )
    return ResolvedResponseBodyCapture(
        preview = preview,
        body = body,
        encoding = "base64".takeIf { body != null && !likelyText },
        truncatedBytes = truncatedBytes,
        bodySize = bodySize,
    )
}

private fun ResponseBodyCapture.isLikelyText(contentType: MediaType?): Boolean = when {
    contentType?.isTextLike() == true -> true
    contentType != null -> false
    else -> body.decodeUtf8TextIfLikely() != null
}

private fun ByteArray.encodeForInspector(likelyText: Boolean, charset: Charset): String? = when {
    isEmpty() -> null
    likelyText -> String(this, charset)
    else -> Base64.encode(this)
}

private fun ResponseBodyCapture.resolvedBodySize(declaredBodySize: Long?): Long = when {
    reachedEof -> totalBytes
    declaredBodySize != null -> maxOf(declaredBodySize, totalBytes)
    else -> totalBytes
}

private fun ResponseBodyCapture.resolvedTruncatedBytes(
    bodySize: Long,
    retainedBytes: Int,
    hasDeclaredBodySize: Boolean,
): Long? {
    val truncatedBytes = (bodySize - retainedBytes.toLong()).coerceAtLeast(0L)
    val truncationIsKnown = reachedEof || hasDeclaredBodySize || totalBytes > retainedBytes
    return truncatedBytes.takeIf { it > 0L && truncationIsKnown }
}

private fun ByteArray.prefix(maxBytes: Int): ByteArray {
    if (maxBytes <= 0 || isEmpty()) return ByteArray(0)
    return if (size <= maxBytes) this else copyOf(maxBytes)
}

private fun hasNonIdentityContentEncoding(contentEncoding: String?): Boolean {
    val encodings = contentEncoding
        ?.split(',')
        ?.map { token -> token.substringBefore(';').trim().lowercase() }
        ?.filter { token -> token.isNotEmpty() }
        .orEmpty()
    return encodings.any { token -> token != "identity" }
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

internal fun resolveEffectiveMaxBytes(maxBytes: Int, contentLength: Long?): Int {
    if (maxBytes <= 0) return 0
    val knownLength = contentLength?.takeIf { it >= 0L } ?: return maxBytes
    return if (knownLength < CompleteBodyCaptureThresholdBytes) {
        maxOf(maxBytes.toLong(), knownLength).toInt()
    } else {
        maxBytes
    }
}

private const val MinLikelyTextRatio: Double = 0.85
private const val SegmentByteCount: Long = 8L * 1024L
private const val CompleteBodyCaptureThresholdBytes: Long = 8L * 1024L * 1024L

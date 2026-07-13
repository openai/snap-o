package com.openai.snapo.network.httpurlconnection

import android.os.SystemClock
import android.util.Base64.NO_WRAP
import android.util.Base64.encodeToString
import com.openai.snapo.network.Header
import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.NetworkInspector
import com.openai.snapo.network.RequestFailed
import com.openai.snapo.network.RequestWillBeSent
import com.openai.snapo.network.ResponseFinished
import com.openai.snapo.network.ResponseReceived
import com.openai.snapo.network.ResponseStreamClosed
import com.openai.snapo.network.ResponseStreamEvent
import com.openai.snapo.network.Timings
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.FilterInputStream
import java.io.FilterOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.ProtocolException
import java.net.URL
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.Permission
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** HttpURLConnection interceptor that mirrors traffic to the active SnapO link if present. */
class SnapOHttpUrlInterceptor @JvmOverloads constructor(
    responseBodyPreviewBytes: Int = DefaultBodyPreviewBytes,
    textBodyMaxBytes: Int = DefaultTextBodyMaxBytes,
    binaryBodyMaxBytes: Int = DefaultBinaryBodyMaxBytes,
    dispatcher: CoroutineDispatcher = DefaultDispatcher,
) : Closeable {

    internal val responseBodyPreviewBytes = responseBodyPreviewBytes.coerceAtLeast(0)
    internal val textBodyMaxBytes = resolveEffectiveMaxBytes(textBodyMaxBytes, contentLength = null)
    internal val binaryBodyMaxBytes = resolveEffectiveMaxBytes(binaryBodyMaxBytes, contentLength = null)
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    fun open(url: URL): HttpURLConnection = intercept(url.openConnection() as HttpURLConnection)

    fun intercept(connection: HttpURLConnection): HttpURLConnection =
        if (NetworkInspector.getOrNull() == null) {
            connection
        } else {
            InterceptingHttpURLConnection(connection, this)
        }

    override fun close() {
        scope.cancel()
    }

    internal fun publish(after: Job? = null, builder: () -> NetworkEventRecord): Job? {
        val server = NetworkInspector.getOrNull() ?: return null
        return scope.launch {
            try {
                after?.join()
                server.publish(builder())
            } catch (_: Throwable) {
            }
        }
    }

    internal fun updateLatestResponseBody(
        requestId: String,
        bodyValues: () -> CapturedBodyValues,
        bodyTruncatedBytes: Long?,
        bodySize: Long?,
        after: Job? = null,
    ): Job? {
        val server = NetworkInspector.getOrNull() ?: return null
        return scope.launch {
            try {
                after?.join()
                val body = bodyValues()
                server.updateLatestResponseBody(
                    requestId = requestId,
                    bodyPreview = body.bodyPreview,
                    body = body.body,
                    bodyEncoding = body.bodyEncoding,
                    bodyTruncatedBytes = bodyTruncatedBytes,
                    bodySize = bodySize,
                )
            } catch (_: Throwable) {
            }
        }
    }

    internal fun updateLatestRequestBody(
        requestId: String,
        bodyValues: () -> RequestBodyValues,
        bodyTruncatedBytes: Long?,
        bodySize: Long?,
        after: Job? = null,
    ): Job? {
        val server = NetworkInspector.getOrNull() ?: return null
        return scope.launch {
            try {
                after?.join()
                val body = bodyValues()
                server.updateLatestRequestBody(
                    requestId = requestId,
                    body = body.body,
                    bodyEncoding = body.encoding,
                    bodyTruncatedBytes = bodyTruncatedBytes,
                    bodySize = bodySize,
                )
            } catch (_: Throwable) {
            }
        }
    }
}

private data class InterceptContext(
    val requestId: String,
    val startWall: Long,
    val startMono: Long,
)

private data class ResponseMeta(
    val code: Int,
    val headers: List<Header>,
    val contentType: String?,
    val contentLength: Long?,
    val responseWall: Long,
    val responseMono: Long,
)

@Suppress("TooManyFunctions")
private class InterceptingHttpURLConnection(
    private val delegate: HttpURLConnection,
    private val interceptor: SnapOHttpUrlInterceptor,
) : HttpURLConnection(delegate.url) {

    private val requestHeaders = snapshotHeaders(delegate)
    private var context: InterceptContext? = null
    private var requestPublished: Boolean = false
    private var requestPublication: Job? = null
    private var publishedRequestBodyBytes: Long = 0L
    private var responseMeta: ResponseMeta? = null
    private var responsePublished: Boolean = false
    private var responsePublication: Job? = null
    private var responseFinishedPublished: Boolean = false
    private var requestBodyCapture: BodyCaptureSink? = null

    override fun connect() {
        ensureRequestPublished()
        delegate.connect()
    }

    override fun disconnect() {
        delegate.disconnect()
    }

    override fun usingProxy(): Boolean = delegate.usingProxy()

    override fun getOutputStream(): OutputStream {
        ensureRequestContext()
        val output = delegate.outputStream
        val capture = ensureRequestBodyCapture() ?: return output
        return CapturingOutputStream(output, capture, ::updatePublishedRequestBody)
    }

    override fun getInputStream(): InputStream {
        ensureRequestPublished()
        return try {
            val input = delegate.inputStream
            wrapResponseStream(input)
        } catch (error: IOException) {
            val responseCode = runCatching { delegate.responseCode }.getOrNull()
            if (responseCode == null) {
                handleFailure(error)
            } else {
                ensureResponseStarted(responseCode)
            }
            throw error
        }
    }

    override fun getErrorStream(): InputStream? {
        ensureRequestPublished()
        val stream = delegate.errorStream ?: return null
        return wrapResponseStream(stream)
    }

    override fun getResponseCode(): Int {
        ensureRequestPublished()
        return try {
            val code = delegate.responseCode
            ensureResponseStarted(code)
            code
        } catch (error: IOException) {
            handleFailure(error)
            throw error
        }
    }

    override fun getResponseMessage(): String? {
        ensureRequestPublished()
        return delegate.responseMessage
    }

    override fun getRequestMethod(): String = delegate.requestMethod

    override fun setInstanceFollowRedirects(followRedirects: Boolean) {
        delegate.instanceFollowRedirects = followRedirects
    }

    override fun getInstanceFollowRedirects(): Boolean = delegate.instanceFollowRedirects

    override fun getHeaderField(name: String?): String? = delegate.getHeaderField(name)

    override fun getHeaderFieldKey(n: Int): String? = delegate.getHeaderFieldKey(n)

    override fun getHeaderField(n: Int): String? = delegate.getHeaderField(n)

    override fun getHeaderFields(): Map<String, List<String>> = delegate.headerFields

    override fun getHeaderFieldInt(name: String?, Default: Int): Int =
        delegate.getHeaderFieldInt(name, Default)

    override fun getHeaderFieldLong(name: String?, Default: Long): Long =
        delegate.getHeaderFieldLong(name, Default)

    override fun getContentLength(): Int = delegate.contentLength

    override fun getContentLengthLong(): Long = delegate.contentLengthLong

    override fun getContentType(): String? = delegate.contentType

    override fun getContentEncoding(): String? = delegate.contentEncoding

    override fun getExpiration(): Long = delegate.expiration

    override fun getDate(): Long = delegate.date

    override fun getLastModified(): Long = delegate.lastModified

    override fun getPermission(): Permission = delegate.permission

    override fun getURL(): URL = delegate.url

    override fun setDoInput(doinput: Boolean) {
        delegate.doInput = doinput
    }

    override fun getDoInput(): Boolean = delegate.doInput

    override fun setDoOutput(dooutput: Boolean) {
        delegate.doOutput = dooutput
    }

    override fun getDoOutput(): Boolean = delegate.doOutput

    override fun setUseCaches(usecaches: Boolean) {
        delegate.useCaches = usecaches
    }

    override fun getUseCaches(): Boolean = delegate.useCaches

    override fun setIfModifiedSince(ifmodifiedsince: Long) {
        delegate.ifModifiedSince = ifmodifiedsince
    }

    override fun getIfModifiedSince(): Long = delegate.ifModifiedSince

    override fun setAllowUserInteraction(allowuserinteraction: Boolean) {
        delegate.allowUserInteraction = allowuserinteraction
    }

    override fun getAllowUserInteraction(): Boolean = delegate.allowUserInteraction

    override fun setDefaultUseCaches(defaultusecaches: Boolean) {
        delegate.defaultUseCaches = defaultusecaches
    }

    override fun getDefaultUseCaches(): Boolean = delegate.defaultUseCaches

    override fun setConnectTimeout(timeout: Int) {
        delegate.connectTimeout = timeout
    }

    override fun getConnectTimeout(): Int = delegate.connectTimeout

    override fun setReadTimeout(timeout: Int) {
        delegate.readTimeout = timeout
    }

    override fun getReadTimeout(): Int = delegate.readTimeout

    override fun addRequestProperty(key: String?, value: String?) {
        delegate.addRequestProperty(key, value)
        addHeader(key, value)
    }

    override fun setRequestProperty(key: String?, value: String?) {
        delegate.setRequestProperty(key, value)
        setHeader(key, value)
    }

    override fun getRequestProperty(key: String?): String? {
        return runCatching { delegate.getRequestProperty(key) }
            .getOrNull()
            ?: headerFirst(key)
    }

    override fun getRequestProperties(): Map<String, List<String>> {
        return runCatching { delegate.requestProperties }
            .getOrNull()
            ?: requestHeaders.toMapCopy()
    }

    override fun setFixedLengthStreamingMode(contentLength: Int) {
        delegate.setFixedLengthStreamingMode(contentLength)
    }

    override fun setFixedLengthStreamingMode(contentLength: Long) {
        delegate.setFixedLengthStreamingMode(contentLength)
    }

    override fun setChunkedStreamingMode(chunklen: Int) {
        delegate.setChunkedStreamingMode(chunklen)
    }

    override fun toString(): String = delegate.toString()

    @Throws(ProtocolException::class)
    override fun setRequestMethod(method: String) {
        delegate.requestMethod = method
    }

    private fun ensureRequestContext() {
        if (context != null) return
        context = InterceptContext(
            requestId = UUID.randomUUID().toString(),
            startWall = System.currentTimeMillis(),
            startMono = SystemClock.elapsedRealtimeNanos(),
        )
    }

    private fun ensureRequestPublished() {
        ensureRequestContext()
        if (requestPublished) {
            updatePublishedRequestBody()
            return
        }
        requestPublished = true
        val currentContext = context ?: return
        val capture = requestBodyCapture?.snapshot()
        val contentType = requestContentType()
        val contentEncoding = requestContentEncoding()
        val mediaType = parseMediaType(contentType)
        val requestBodyBytes = capture?.bytes
        val bodySize = capture?.totalBytes ?: requestContentLength()
        val truncatedBytes = capture?.truncatedBytes
        val hasBody = delegate.doOutput || requestBodyCapture != null || (bodySize?.let { it > 0L } == true)
        publishedRequestBodyBytes = capture?.totalBytes ?: 0L

        requestPublication = interceptor.publish {
            val bodyValues = resolveRequestBodyValues(
                bytes = requestBodyBytes,
                mediaType = mediaType,
                contentEncoding = contentEncoding,
                hasBody = hasBody,
            )
            RequestWillBeSent(
                id = currentContext.requestId,
                tWallMs = currentContext.startWall,
                tMonoNs = currentContext.startMono,
                method = delegate.requestMethod,
                url = delegate.url.toString(),
                headers = requestHeaders.toMapCopy().toHeaderList(),
                hasBody = hasBody,
                body = bodyValues.body,
                bodyEncoding = bodyValues.encoding,
                bodyTruncatedBytes = truncatedBytes,
                bodySize = bodySize,
            )
        }
    }

    private fun updatePublishedRequestBody() {
        if (!requestPublished) return
        val currentContext = context ?: return
        val capture = requestBodyCapture?.snapshot() ?: return
        if (capture.totalBytes == publishedRequestBodyBytes) return
        publishedRequestBodyBytes = capture.totalBytes
        val mediaType = parseMediaType(requestContentType())
        val contentEncoding = requestContentEncoding()
        requestPublication = interceptor.updateLatestRequestBody(
            requestId = currentContext.requestId,
            bodyValues = {
                resolveRequestBodyValues(
                    bytes = capture.bytes,
                    mediaType = mediaType,
                    contentEncoding = contentEncoding,
                )
            },
            bodyTruncatedBytes = capture.truncatedBytes,
            bodySize = maxOf(requestContentLength() ?: 0L, capture.totalBytes),
            after = requestPublication,
        ) ?: requestPublication
    }

    private fun ensureResponseStarted(code: Int? = null): ResponseMeta? {
        responseMeta?.let { return it }
        val currentContext = context ?: return null
        val responseCode = code ?: runCatching { delegate.responseCode }.getOrNull() ?: return null
        val responseWall = System.currentTimeMillis()
        val responseMono = SystemClock.elapsedRealtimeNanos()
        val headers = delegate.headerFields.toHeaderList()
        val contentType = delegate.contentType
        val contentLength = delegate.contentLengthLong.takeIf { it >= 0L }
        val meta = ResponseMeta(
            code = responseCode,
            headers = headers,
            contentType = contentType,
            contentLength = contentLength,
            responseWall = responseWall,
            responseMono = responseMono,
        )
        responseMeta = meta

        if (!responsePublished) {
            responsePublished = true
            responsePublication = interceptor.publish(after = requestPublication) {
                ResponseReceived(
                    id = currentContext.requestId,
                    tWallMs = responseWall,
                    tMonoNs = responseMono,
                    code = responseCode,
                    headers = headers,
                    bodyPreview = null,
                    body = null,
                    bodyEncoding = null,
                    bodyTruncatedBytes = null,
                    bodySize = contentLength,
                    timings = Timings(totalMs = nanosToMillis(responseMono - currentContext.startMono)),
                )
            }
        }
        if (responseHasNoBody(method = delegate.requestMethod, code = responseCode, contentLength = contentLength)) {
            publishLoadingFinishedOnce(totalBytes = contentLength ?: 0L)
        }
        return meta
    }

    private fun wrapResponseStream(stream: InputStream): InputStream {
        val meta = ensureResponseStarted()
        if (meta != null && responseHasNoBody(
                method = delegate.requestMethod,
                code = meta.code,
                contentLength = meta.contentLength,
            )
        ) {
            return stream
        }
        val mediaType = parseMediaType(meta?.contentType)
        if (mediaType?.isEventStream() == true) {
            return SseCapturingInputStream(
                delegate = stream,
                interceptor = interceptor,
                context = context,
                charset = mediaType.charsetOrUtf8(),
                initialPublication = responsePublication,
            )
        }
        val effectiveMax = resolveEffectiveMaxBytes(
            maxBytes = if (mediaType?.isTextLike() == true) {
                interceptor.textBodyMaxBytes
            } else {
                interceptor.binaryBodyMaxBytes
            },
            contentLength = meta?.contentLength,
        )
        val capture = BodyCaptureSink(effectiveMax)
        return ResponseCapturingInputStream(
            delegate = stream,
            capture = capture,
            interceptor = interceptor,
            mediaType = mediaType,
            captureContext = ResponseCaptureContext(
                request = context,
                response = meta,
                publication = responsePublication,
            ),
        )
    }

    private fun ensureRequestBodyCapture(): BodyCaptureSink? {
        val mediaType = parseMediaType(requestContentType())
        val captureLimit = if (
            hasNonIdentityContentEncoding(requestContentEncoding()) || mediaType?.isTextLike() != true
        ) {
            interceptor.binaryBodyMaxBytes
        } else {
            interceptor.textBodyMaxBytes
        }
        if (captureLimit <= 0) return null
        return requestBodyCapture ?: BodyCaptureSink(captureLimit).also {
            requestBodyCapture = it
        }
    }

    private fun handleFailure(error: Throwable) {
        val currentContext = context ?: return
        val failWall = System.currentTimeMillis()
        val failMono = SystemClock.elapsedRealtimeNanos()
        interceptor.publish(after = requestPublication) {
            RequestFailed(
                id = currentContext.requestId,
                tWallMs = failWall,
                tMonoNs = failMono,
                errorKind = error.javaClass.simpleName.ifEmpty { error.javaClass.name },
                message = error.message,
                timings = Timings(totalMs = nanosToMillis(failMono - currentContext.startMono)),
            )
        }
    }

    private fun publishLoadingFinishedOnce(totalBytes: Long?) {
        if (responseFinishedPublished) return
        val currentContext = context ?: return
        responseFinishedPublished = true
        val nowWall = System.currentTimeMillis()
        val nowMono = SystemClock.elapsedRealtimeNanos()
        interceptor.publish(after = responsePublication) {
            ResponseFinished(
                id = currentContext.requestId,
                tWallMs = nowWall,
                tMonoNs = nowMono,
                bodySize = totalBytes,
            )
        }
    }

    private fun responseHasNoBody(method: String?, code: Int, contentLength: Long?): Boolean {
        if (method.equals("HEAD", ignoreCase = true)) return true
        if (code in 100..199) return true
        if (code == HttpURLConnection.HTTP_NO_CONTENT) return true
        if (code == HttpURLConnection.HTTP_RESET) return true
        if (code == HttpURLConnection.HTTP_NOT_MODIFIED) return true
        return contentLength == 0L
    }

    private fun requestContentType(): String? {
        return headerFirst("Content-Type")
    }

    private fun requestContentLength(): Long? {
        return headerFirst("Content-Length")?.toLongOrNull()
    }

    private fun requestContentEncoding(): String? {
        return headerFirst("Content-Encoding")
    }

    private fun addHeader(key: String?, value: String?) {
        if (key == null || value == null) return
        val existingKey = requestHeaders.keys.firstOrNull { it.equals(key, ignoreCase = true) } ?: key
        requestHeaders.getOrPut(existingKey) { mutableListOf() }.add(value)
    }

    private fun setHeader(key: String?, value: String?) {
        if (key == null) return
        val existingKey = requestHeaders.keys.firstOrNull { it.equals(key, ignoreCase = true) } ?: key
        if (value == null) {
            requestHeaders.remove(existingKey)
            return
        }
        requestHeaders[existingKey] = mutableListOf(value)
    }

    private fun headerFirst(key: String?): String? {
        if (key == null) return null
        val matchingKey = requestHeaders.keys.firstOrNull { it.equals(key, ignoreCase = true) } ?: return null
        return requestHeaders[matchingKey]?.firstOrNull()
    }

    private fun LinkedHashMap<String, MutableList<String>>.toMapCopy(): Map<String, List<String>> {
        if (isEmpty()) return emptyMap()
        val copy = LinkedHashMap<String, List<String>>(size)
        for ((key, values) in this) {
            copy[key] = values.toList()
        }
        return copy
    }

    private fun snapshotHeaders(connection: HttpURLConnection): LinkedHashMap<String, MutableList<String>> {
        val snapshot = LinkedHashMap<String, MutableList<String>>()
        val properties = runCatching { connection.requestProperties }.getOrNull() ?: return snapshot
        for ((key, values) in properties) {
            if (key == null) continue
            snapshot[key] = values.toMutableList()
        }
        return snapshot
    }

    private fun Map<out String?, List<String>>.toHeaderList(): List<Header> {
        if (isEmpty()) return emptyList()
        val headers = ArrayList<Header>(size)
        for ((key, values) in this) {
            if (key == null) continue
            for (value in values) {
                headers.add(Header(key, value))
            }
        }
        return headers
    }
}

private class BodyCaptureSink(private val maxBytes: Int) {
    private val buffer = ByteArrayOutputStream(maxBytes.coerceAtLeast(0).coerceAtMost(1024))
    var totalBytes: Long = 0L
        private set

    fun append(bytes: ByteArray, offset: Int, length: Int) {
        if (length <= 0) return
        totalBytes += length.toLong()
        if (maxBytes <= 0) return
        val remaining = maxBytes - buffer.size()
        if (remaining <= 0) return
        val toWrite = length.coerceAtMost(remaining)
        buffer.write(bytes, offset, toWrite)
    }

    fun snapshot(): BodyCaptureSnapshot {
        val captured = buffer.toByteArray()
        val truncated = (totalBytes - captured.size.toLong()).coerceAtLeast(0L)
        return BodyCaptureSnapshot(captured, totalBytes, truncated.takeIf { it > 0L })
    }
}

private data class BodyCaptureSnapshot(
    val bytes: ByteArray,
    val totalBytes: Long,
    val truncatedBytes: Long?,
)

internal data class RequestBodyValues(
    val body: String?,
    val encoding: String?,
)

private fun resolveRequestBodyValues(
    bytes: ByteArray?,
    mediaType: ParsedMediaType?,
    contentEncoding: String?,
    hasBody: Boolean = true,
): RequestBodyValues {
    val usesBase64 = hasNonIdentityContentEncoding(contentEncoding) || mediaType?.isTextLike() != true
    if (bytes == null || bytes.isEmpty()) {
        return RequestBodyValues(
            body = null,
            encoding = "base64".takeIf { hasBody && usesBase64 },
        )
    }
    return when {
        usesBase64 ->
            RequestBodyValues(body = encodeToString(bytes, NO_WRAP), encoding = "base64")
        else -> RequestBodyValues(body = String(bytes, mediaType.charsetOrUtf8()), encoding = null)
    }
}

private class CapturingOutputStream(
    delegate: OutputStream,
    private val capture: BodyCaptureSink,
    private val onClosed: () -> Unit,
) : FilterOutputStream(delegate) {

    private val closed = AtomicBoolean(false)

    override fun write(b: Int) {
        out.write(b)
        capture.append(byteArrayOf(b.toByte()), 0, 1)
    }

    override fun write(b: ByteArray, off: Int, len: Int) {
        out.write(b, off, len)
        capture.append(b, off, len)
    }

    override fun close() {
        try {
            super.close()
        } finally {
            if (closed.compareAndSet(false, true)) {
                try {
                    onClosed()
                } catch (_: Throwable) {
                }
            }
        }
    }
}

private data class ResponseCaptureContext(
    val request: InterceptContext?,
    val response: ResponseMeta?,
    val publication: Job?,
)

private class ResponseCapturingInputStream(
    delegate: InputStream,
    private val capture: BodyCaptureSink,
    private val interceptor: SnapOHttpUrlInterceptor,
    private val mediaType: ParsedMediaType?,
    private val captureContext: ResponseCaptureContext,
) : FilterInputStream(delegate) {

    private val completed = AtomicBoolean(false)

    override fun read(): Int {
        return try {
            val value = super.read()
            if (value >= 0) {
                capture.append(byteArrayOf(value.toByte()), 0, 1)
            } else {
                complete(null)
            }
            value
        } catch (error: IOException) {
            complete(error)
            throw error
        }
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        return try {
            val count = super.read(b, off, len)
            if (count > 0) {
                capture.append(b, off, count)
            } else if (count == -1) {
                complete(null)
            }
            count
        } catch (error: IOException) {
            complete(error)
            throw error
        }
    }

    override fun close() {
        try {
            super.close()
        } finally {
            complete(null)
        }
    }

    private fun complete(error: Throwable?) {
        if (!completed.compareAndSet(false, true)) return
        val currentContext = captureContext.request ?: return
        val snapshot = capture.snapshot()
        val meta = captureContext.response
        val totalBytes = snapshot.totalBytes.takeIf { it > 0L } ?: meta?.contentLength
        val bodyUpdate = interceptor.updateLatestResponseBody(
            requestId = currentContext.requestId,
            bodyValues = {
                resolveCapturedBodyValues(
                    bytes = snapshot.bytes,
                    mediaType = mediaType,
                    previewBytes = interceptor.responseBodyPreviewBytes,
                )
            },
            bodyTruncatedBytes = snapshot.truncatedBytes,
            bodySize = totalBytes,
            after = captureContext.publication,
        )
        publishLoadingFinishedIfNeeded(
            requestId = currentContext.requestId,
            totalBytes = totalBytes,
            truncatedBytes = snapshot.truncatedBytes,
            error = error,
            after = bodyUpdate,
        )
        publishFailureIfNeeded(currentContext, error, after = bodyUpdate)
    }

    private fun resolveCapturedBodyValues(
        bytes: ByteArray,
        mediaType: ParsedMediaType?,
        previewBytes: Int,
    ): CapturedBodyValues {
        if (bytes.isEmpty()) {
            return CapturedBodyValues(
                bodyPreview = null,
                body = null,
                bodyEncoding = null,
            )
        }
        val charset = mediaType?.charsetOrUtf8() ?: Charsets.UTF_8
        val isKnownText = mediaType?.isTextLike() == true
        val bodyText = if (isKnownText) {
            String(bytes, charset)
        } else if (mediaType == null) {
            decodeUtf8TextIfLikely(bytes)
        } else {
            null
        }

        return if (bodyText != null) {
            val preview = if (previewBytes > 0) {
                val limit = previewBytes.coerceAtMost(bytes.size)
                String(bytes, 0, limit, charset)
            } else {
                null
            }
            CapturedBodyValues(
                bodyPreview = preview,
                body = bodyText,
                bodyEncoding = null,
            )
        } else {
            val preview = if (previewBytes > 0) {
                val limit = previewBytes.coerceAtMost(bytes.size)
                encodeToString(bytes, 0, limit, NO_WRAP)
            } else {
                null
            }
            CapturedBodyValues(
                bodyPreview = preview,
                body = encodeToString(bytes, NO_WRAP),
                bodyEncoding = "base64",
            )
        }
    }

    private fun publishLoadingFinishedIfNeeded(
        requestId: String,
        totalBytes: Long?,
        truncatedBytes: Long?,
        error: Throwable?,
        after: Job?,
    ) {
        if (error != null) return
        val nowWall = System.currentTimeMillis()
        val nowMono = SystemClock.elapsedRealtimeNanos()
        interceptor.publish(after = after) {
            ResponseFinished(
                id = requestId,
                tWallMs = nowWall,
                tMonoNs = nowMono,
                bodySize = totalBytes,
                bodyTruncatedBytes = truncatedBytes,
            )
        }
    }

    private fun publishFailureIfNeeded(currentContext: InterceptContext, error: Throwable?, after: Job?) {
        if (error == null) return
        val failWall = System.currentTimeMillis()
        val failMono = SystemClock.elapsedRealtimeNanos()
        interceptor.publish(after = after) {
            RequestFailed(
                id = currentContext.requestId,
                tWallMs = failWall,
                tMonoNs = failMono,
                errorKind = error.javaClass.simpleName.ifEmpty { error.javaClass.name },
                message = error.message,
                timings = Timings(totalMs = nanosToMillis(failMono - currentContext.startMono)),
            )
        }
    }
}

internal data class CapturedBodyValues(
    val bodyPreview: String?,
    val body: String?,
    val bodyEncoding: String?,
)

private fun decodeUtf8TextIfLikely(bytes: ByteArray): String? {
    if (bytes.isEmpty()) return ""
    val decoded = runCatching {
        Charsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    }.getOrNull() ?: return null
    if (decoded.isEmpty()) return decoded
    val printable = decoded.count { ch ->
        ch == '\n' || ch == '\r' || ch == '\t' || (ch >= ' ' && ch != '\u007f')
    }
    val printableRatio = printable.toDouble() / decoded.length.toDouble()
    return decoded.takeIf { printableRatio >= MinLikelyTextRatio }
}

private class SseCapturingInputStream(
    delegate: InputStream,
    private val interceptor: SnapOHttpUrlInterceptor,
    private val context: InterceptContext?,
    private val charset: java.nio.charset.Charset,
    initialPublication: Job?,
) : FilterInputStream(delegate) {

    private val parser = SseBuffer(charset)
    private val closed = AtomicBoolean(false)
    private val publicationLock = Any()
    private var previousPublication = initialPublication
    private var totalBytes: Long = 0L
    private var nextSequence: Long = 0L

    override fun read(): Int {
        return try {
            val value = super.read()
            if (value >= 0) {
                handleBytes(byteArrayOf(value.toByte()))
            } else {
                onClosed(null)
            }
            value
        } catch (error: IOException) {
            onClosed(error)
            throw error
        }
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        return try {
            val count = super.read(b, off, len)
            if (count > 0) {
                handleBytes(b.copyOfRange(off, off + count))
            } else if (count == -1) {
                onClosed(null)
            }
            count
        } catch (error: IOException) {
            onClosed(error)
            throw error
        }
    }

    override fun close() {
        try {
            super.close()
        } finally {
            onClosed(null)
        }
    }

    private fun handleBytes(bytes: ByteArray) {
        val currentContext = context ?: return
        if (bytes.isEmpty()) return
        totalBytes += bytes.size.toLong()
        val events = parser.append(bytes)
        for (raw in events) {
            val sequence = ++nextSequence
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            publish {
                ResponseStreamEvent(
                    id = currentContext.requestId,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    sequence = sequence,
                    raw = raw,
                )
            }
        }
    }

    private fun onClosed(error: Throwable?) {
        if (!closed.compareAndSet(false, true)) return
        val currentContext = context ?: return
        val tailEvents = parser.drainRemaining()
        for (raw in tailEvents) {
            val sequence = ++nextSequence
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            publish {
                ResponseStreamEvent(
                    id = currentContext.requestId,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    sequence = sequence,
                    raw = raw,
                )
            }
        }

        val nowWall = System.currentTimeMillis()
        val nowMono = SystemClock.elapsedRealtimeNanos()
        publish {
            ResponseStreamClosed(
                id = currentContext.requestId,
                tWallMs = nowWall,
                tMonoNs = nowMono,
                reason = if (error == null) "completed" else "error",
                message = error?.message ?: error?.javaClass?.simpleName,
                totalEvents = nextSequence,
                totalBytes = totalBytes,
            )
        }
    }

    private fun publish(builder: () -> NetworkEventRecord) {
        synchronized(publicationLock) {
            previousPublication = interceptor.publish(
                after = previousPublication,
                builder = builder,
            ) ?: previousPublication
        }
    }
}

private data class ParsedMediaType(
    val type: String,
    val subtype: String,
    val charset: java.nio.charset.Charset?,
)

private fun parseMediaType(value: String?): ParsedMediaType? {
    val raw = value ?: return null
    val parts = raw.split(';')
    val typePart = parts.firstOrNull()?.trim().orEmpty()
    val typePieces = typePart.split('/')
    if (typePieces.size != 2) return null
    val type = typePieces[0].trim().lowercase()
    val subtype = typePieces[1].trim().lowercase()
    if (type.isEmpty() || subtype.isEmpty()) return null

    var charset: java.nio.charset.Charset? = null
    for (index in 1 until parts.size) {
        val rawCharset = extractCharset(parts[index].trim())
        if (rawCharset != null) {
            charset = runCatching { java.nio.charset.Charset.forName(rawCharset) }.getOrNull()
        }
    }

    return ParsedMediaType(type = type, subtype = subtype, charset = charset)
}

private fun ParsedMediaType.isTextLike(): Boolean {
    if (type == "text") return true
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
    ).any(subtype::contains)
}

private fun ParsedMediaType.isEventStream(): Boolean =
    type == "text" && subtype == "event-stream"

private fun ParsedMediaType.charsetOrUtf8(): java.nio.charset.Charset =
    charset ?: Charsets.UTF_8

private fun extractCharset(param: String): String? {
    if (!param.startsWith("charset=", ignoreCase = true)) return null
    val valueStart = param.indexOf('=') + 1
    if (valueStart <= 0 || valueStart >= param.length) return null
    return param.substring(valueStart).trim().trim('"')
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

private fun nanosToMillis(deltaNs: Long): Long? {
    if (deltaNs <= 0L) return null
    return TimeUnit.NANOSECONDS.toMillis(deltaNs)
}

private class SseBuffer(private val charset: java.nio.charset.Charset) {
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

private fun ByteArray.toNormalizedString(charset: java.nio.charset.Charset): String {
    val raw = String(this, charset)
    if (raw.indexOf('\r') == -1) return raw
    return raw.replace("\r\n", "\n").replace('\r', '\n')
}

private fun hasNonIdentityContentEncoding(contentEncoding: String?): Boolean {
    val encodings = contentEncoding
        ?.split(',')
        ?.map { token -> token.substringBefore(';').trim().lowercase() }
        ?.filter { token -> token.isNotEmpty() }
        .orEmpty()
    return encodings.any { token -> token != "identity" }
}

private val DefaultDispatcher: CoroutineDispatcher = Dispatchers.Default
private const val DefaultBodyPreviewBytes: Int = 4096
private const val DefaultTextBodyMaxBytes: Int = 5 * 1024 * 1024
private const val DefaultBinaryBodyMaxBytes: Int = DefaultTextBodyMaxBytes
private const val MinLikelyTextRatio: Double = 0.85
private const val CompleteBodyCaptureThresholdBytes: Long = 8L * 1024L * 1024L

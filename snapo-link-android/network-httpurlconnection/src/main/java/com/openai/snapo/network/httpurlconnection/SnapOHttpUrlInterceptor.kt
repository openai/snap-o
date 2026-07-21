package com.openai.snapo.network.httpurlconnection

import android.os.SystemClock
import com.openai.snapo.network.Header
import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.NetworkInspector
import com.openai.snapo.network.RequestWillBeSent
import com.openai.snapo.network.ResponseReceived
import com.openai.snapo.network.Timings
import com.openai.snapo.network.capture.BodyContentType
import com.openai.snapo.network.capture.CaptureEventPublisher
import com.openai.snapo.network.capture.DefaultBinaryBodyMaxBytes
import com.openai.snapo.network.capture.DefaultBodyPreviewBytes
import com.openai.snapo.network.capture.DefaultTextBodyMaxBytes
import com.openai.snapo.network.capture.RawResponseBodyCapture
import com.openai.snapo.network.capture.SseStreamCapture
import com.openai.snapo.network.capture.resolveEffectiveMaxBytes
import com.openai.snapo.network.capture.resolveRequestBody
import com.openai.snapo.network.capture.resolveRequestCaptureLimit
import com.openai.snapo.network.capture.resolveResponseCaptureLimit
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
    internal val publisher = CaptureEventPublisher(
        responseBodyPreviewBytes = this.responseBodyPreviewBytes,
        textBodyMaxBytes = this.textBodyMaxBytes,
        binaryBodyMaxBytes = this.binaryBodyMaxBytes,
        dispatcher = dispatcher,
    )

    fun open(url: URL): HttpURLConnection = intercept(url.openConnection() as HttpURLConnection)

    fun intercept(connection: HttpURLConnection): HttpURLConnection =
        if (NetworkInspector.getOrNull() == null) {
            connection
        } else {
            InterceptingHttpURLConnection(connection, this)
        }

    override fun close() {
        publisher.close()
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
        val mediaType = BodyContentType.parse(contentType)
        val requestBodyBytes = capture?.bytes
        val bodySize = capture?.totalBytes ?: requestContentLength()
        val truncatedBytes = capture?.truncatedBytes
        val hasBody = delegate.doOutput || requestBodyCapture != null || (bodySize?.let { it > 0L } == true)
        publishedRequestBodyBytes = capture?.totalBytes ?: 0L

        requestPublication = interceptor.publisher.publish {
            val bodyValues = resolveRequestBody(
                bytes = requestBodyBytes,
                contentType = mediaType,
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
        val mediaType = BodyContentType.parse(requestContentType())
        val contentEncoding = requestContentEncoding()
        requestPublication = interceptor.publisher.updateRequestBody(
            requestId = currentContext.requestId,
            bodyValues = {
                resolveRequestBody(
                    bytes = capture.bytes,
                    contentType = mediaType,
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
            responsePublication = interceptor.publisher.publish(after = requestPublication) {
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
        val mediaType = BodyContentType.parse(meta?.contentType)
        if (mediaType?.isEventStream == true) {
            return SseCapturingInputStream(
                delegate = stream,
                interceptor = interceptor,
                context = context,
                charset = mediaType.charsetOrUtf8(),
                initialPublication = responsePublication,
            )
        }
        val effectiveMax = resolveResponseCaptureLimit(
            contentType = mediaType,
            contentLength = meta?.contentLength,
            textBodyMaxBytes = interceptor.textBodyMaxBytes,
            binaryBodyMaxBytes = interceptor.binaryBodyMaxBytes,
            previewBytes = interceptor.responseBodyPreviewBytes,
        )
        return ResponseCapturingInputStream(
            delegate = stream,
            maxBytes = effectiveMax,
            onComplete = completion@{ capture, error ->
                val currentContext = context ?: return@completion
                interceptor.publisher.completeResponse(
                    requestId = currentContext.requestId,
                    requestStartMono = currentContext.startMono,
                    capture = capture,
                    contentType = mediaType,
                    declaredBodySize = meta?.contentLength,
                    error = error,
                    after = responsePublication,
                )
            },
        )
    }

    private fun ensureRequestBodyCapture(): BodyCaptureSink? {
        val mediaType = BodyContentType.parse(requestContentType())
        val captureLimit = resolveRequestCaptureLimit(
            contentType = mediaType,
            contentEncoding = requestContentEncoding(),
            textBodyMaxBytes = interceptor.textBodyMaxBytes,
            binaryBodyMaxBytes = interceptor.binaryBodyMaxBytes,
        )
        if (captureLimit <= 0) return null
        return requestBodyCapture ?: BodyCaptureSink(captureLimit).also {
            requestBodyCapture = it
        }
    }

    private fun handleFailure(error: Throwable) {
        val currentContext = context ?: return
        interceptor.publisher.publishFailure(
            requestId = currentContext.requestId,
            requestStartMono = currentContext.startMono,
            error = error,
            after = requestPublication,
        )
    }

    private fun publishLoadingFinishedOnce(totalBytes: Long?) {
        if (responseFinishedPublished) return
        val currentContext = context ?: return
        responseFinishedPublished = true
        interceptor.publisher.publishFinished(
            requestId = currentContext.requestId,
            bodySize = totalBytes,
            after = responsePublication,
        )
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

internal class ResponseCapturingInputStream(
    delegate: InputStream,
    maxBytes: Int,
    private val onComplete: (RawResponseBodyCapture, Throwable?) -> Unit,
) : FilterInputStream(delegate) {

    private val completed = AtomicBoolean(false)
    private val capture = BodyCaptureSink(maxBytes)

    override fun read(): Int {
        return try {
            val value = super.read()
            if (value >= 0) {
                capture.append(byteArrayOf(value.toByte()), 0, 1)
            } else {
                complete(error = null, reachedEof = true)
            }
            value
        } catch (error: IOException) {
            complete(error = error, reachedEof = false)
            throw error
        }
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        return try {
            val count = super.read(b, off, len)
            if (count > 0) {
                capture.append(b, off, count)
            } else if (count == -1) {
                complete(error = null, reachedEof = true)
            }
            count
        } catch (error: IOException) {
            complete(error = error, reachedEof = false)
            throw error
        }
    }

    override fun close() {
        val result = runCatching { super.close() }
        complete(error = result.exceptionOrNull(), reachedEof = false)
        result.getOrThrow()
    }

    private fun complete(error: Throwable?, reachedEof: Boolean) {
        if (!completed.compareAndSet(false, true)) return
        val snapshot = capture.snapshot()
        try {
            onComplete(
                RawResponseBodyCapture(
                    bytes = snapshot.bytes,
                    totalBytes = snapshot.totalBytes,
                    reachedEof = reachedEof,
                ),
                error,
            )
        } catch (_: Throwable) {
        }
    }
}

private class SseCapturingInputStream(
    delegate: InputStream,
    private val interceptor: SnapOHttpUrlInterceptor,
    context: InterceptContext?,
    charset: java.nio.charset.Charset,
    initialPublication: Job?,
) : FilterInputStream(delegate) {

    private val publicationLock = Any()
    private var previousPublication = initialPublication
    private val capture = context?.let { currentContext ->
        SseStreamCapture(
            requestId = currentContext.requestId,
            charset = charset,
        ) { record ->
            publish { record }
        }
    }

    override fun read(): Int {
        return try {
            val value = super.read()
            if (value >= 0) {
                capture?.append(byteArrayOf(value.toByte()))
            } else {
                capture?.complete()
            }
            value
        } catch (error: IOException) {
            capture?.complete(error)
            throw error
        }
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        return try {
            val count = super.read(b, off, len)
            if (count > 0) {
                capture?.append(b, offset = off, length = count)
            } else if (count == -1) {
                capture?.complete()
            }
            count
        } catch (error: IOException) {
            capture?.complete(error)
            throw error
        }
    }

    override fun close() {
        val result = runCatching { super.close() }
        capture?.complete(result.exceptionOrNull())
        result.getOrThrow()
    }

    private fun publish(builder: () -> NetworkEventRecord) {
        synchronized(publicationLock) {
            previousPublication = interceptor.publisher.publish(
                after = previousPublication,
                builder = builder,
            ) ?: previousPublication
        }
    }
}

private fun nanosToMillis(deltaNs: Long): Long? {
    if (deltaNs <= 0L) return null
    return TimeUnit.NANOSECONDS.toMillis(deltaNs)
}

private val DefaultDispatcher: CoroutineDispatcher = Dispatchers.Default

package com.openai.snapo.link.okhttp3

import android.os.SystemClock
import android.util.Base64.NO_WRAP
import android.util.Base64.encodeToString
import com.openai.snapo.link.core.RequestFailed
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
import java.io.Closeable
import java.io.IOException
import java.nio.charset.Charset
import java.util.UUID
import java.util.concurrent.TimeUnit
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
            val bodyPreview = textBody?.preview ?: response.bodyPreview(responseBodyPreviewBytes)
            val truncatedBytes = textBody?.truncatedBytes(bodySize)
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

private const val AbsoluteBodyTextMaxBytes: Long = 8L * 1024L * 1024L

package com.openai.snapo.network.capture

import android.os.SystemClock
import androidx.annotation.RestrictTo
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
import java.io.Closeable
import java.util.concurrent.TimeUnit

/** Publishes client-neutral capture updates with optional predecessor ordering. */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
@Suppress("LongParameterList")
class CaptureEventPublisher internal constructor(
    private val responseBodyPreviewBytes: Int,
    private val textBodyMaxBytes: Int,
    private val binaryBodyMaxBytes: Int,
    dispatcher: CoroutineDispatcher,
    private val sinkProvider: () -> CaptureEventSink?,
    private val wallTimeMillis: () -> Long,
    private val monotonicNanos: () -> Long,
) : Closeable {

    constructor(
        responseBodyPreviewBytes: Int,
        textBodyMaxBytes: Int,
        binaryBodyMaxBytes: Int,
        dispatcher: CoroutineDispatcher,
    ) : this(
        responseBodyPreviewBytes = responseBodyPreviewBytes,
        textBodyMaxBytes = textBodyMaxBytes,
        binaryBodyMaxBytes = binaryBodyMaxBytes,
        dispatcher = dispatcher,
        sinkProvider = {
            NetworkInspector.getOrNull()?.let { server ->
                CaptureEventSink(
                    publish = server::publish,
                    updateRequestBody = server::updateLatestRequestBody,
                    updateResponseBody = server::updateLatestResponseBody,
                )
            }
        },
        wallTimeMillis = System::currentTimeMillis,
        monotonicNanos = SystemClock::elapsedRealtimeNanos,
    )

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    @Volatile
    private var activeSink: CaptureEventSink? = null

    override fun close() {
        scope.cancel()
    }

    fun publish(after: Job? = null, builder: () -> NetworkEventRecord): Job? = launch(after) { sink ->
        sink.publish(builder())
    }

    fun updateRequestBody(
        requestId: String,
        bodyValues: () -> ResolvedRequestBody,
        bodyTruncatedBytes: Long?,
        bodySize: Long?,
        after: Job? = null,
    ): Job? = launch(after) { sink ->
        val body = bodyValues()
        sink.updateRequestBody(
            requestId,
            body.body,
            body.encoding,
            bodyTruncatedBytes,
            bodySize,
        )
    }

    fun completeResponse(
        requestId: String,
        requestStartMono: Long,
        capture: RawResponseBodyCapture,
        contentType: BodyContentType?,
        declaredBodySize: Long?,
        error: Throwable?,
        after: Job? = null,
    ): Job? {
        val completionWall = wallTimeMillis()
        val completionMono = monotonicNanos()
        return launch(after) { sink ->
            val body = runCatching {
                resolveResponseBody(
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
                    sink.updateResponseBody(
                        requestId,
                        body.preview,
                        body.body,
                        body.encoding,
                        body.truncatedBytes,
                        body.bodySize,
                    )
                }
            }
            sink.publish(
                if (error == null) {
                    ResponseFinished(
                        id = requestId,
                        tWallMs = completionWall,
                        tMonoNs = completionMono,
                        bodySize = body?.bodySize ?: declaredBodySize ?: capture.totalBytes,
                        bodyTruncatedBytes = body?.truncatedBytes,
                    )
                } else {
                    failureRecord(requestId, requestStartMono, completionWall, completionMono, error)
                },
            )
        }
    }

    fun publishFailure(
        requestId: String,
        requestStartMono: Long,
        error: Throwable,
        after: Job? = null,
    ): Job? {
        val failureWall = wallTimeMillis()
        val failureMono = monotonicNanos()
        return publish(after) {
            failureRecord(requestId, requestStartMono, failureWall, failureMono, error)
        }
    }

    fun publishFinished(requestId: String, bodySize: Long?, after: Job? = null): Job? {
        val finishWall = wallTimeMillis()
        val finishMono = monotonicNanos()
        return publish(after) {
            ResponseFinished(
                id = requestId,
                tWallMs = finishWall,
                tMonoNs = finishMono,
                bodySize = bodySize,
            )
        }
    }

    private fun launch(after: Job?, block: suspend (CaptureEventSink) -> Unit): Job? {
        val sink = activeSink ?: synchronized(this) {
            activeSink ?: sinkProvider()?.also { activeSink = it }
        } ?: return null
        return scope.launch {
            try {
                after?.join()
                block(sink)
            } catch (_: Throwable) {
            }
        }
    }

    private fun failureRecord(
        requestId: String,
        requestStartMono: Long,
        wallTime: Long,
        monotonicTime: Long,
        error: Throwable,
    ): RequestFailed = RequestFailed(
        id = requestId,
        tWallMs = wallTime,
        tMonoNs = monotonicTime,
        errorKind = error.javaClass.simpleName.ifEmpty { error.javaClass.name },
        message = error.message,
        timings = Timings(
            totalMs = TimeUnit.NANOSECONDS.toMillis(monotonicTime - requestStartMono)
                .takeIf { monotonicTime > requestStartMono },
        ),
    )
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
internal data class CaptureEventSink(
    val publish: suspend (NetworkEventRecord) -> Unit,
    val updateRequestBody: suspend (String, String?, String?, Long?, Long?) -> Unit,
    val updateResponseBody: suspend (String, String?, String?, String?, Long?, Long?) -> Unit,
)

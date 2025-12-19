package com.openai.snapo.network.okhttp3

import android.os.SystemClock
import com.openai.snapo.link.core.Header
import com.openai.snapo.link.core.SnapOLink
import com.openai.snapo.link.core.SnapONetRecord
import com.openai.snapo.link.core.WebSocketCancelled
import com.openai.snapo.link.core.WebSocketCloseRequested
import com.openai.snapo.link.core.WebSocketClosed
import com.openai.snapo.link.core.WebSocketClosing
import com.openai.snapo.link.core.WebSocketFailed
import com.openai.snapo.link.core.WebSocketMessageReceived
import com.openai.snapo.link.core.WebSocketMessageSent
import com.openai.snapo.link.core.WebSocketOpened
import com.openai.snapo.link.core.WebSocketWillOpen
import com.openai.snapo.network.NetworkInspector
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import okhttp3.Headers
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.ArrayList
import java.util.UUID
import kotlin.math.min

fun WebSocket.Factory.withSnapOInterceptor(
    textPreviewChars: Int = DefaultTextPreviewChars,
    binaryPreviewBytes: Int = DefaultBinaryPreviewBytes,
    dispatcher: CoroutineDispatcher = DefaultDispatcher,
): WebSocket.Factory = SnapOInterceptorWebSocketFactory(
    delegate = this,
    textPreviewChars = textPreviewChars,
    binaryPreviewBytes = binaryPreviewBytes,
    dispatcher = dispatcher,
)

/**
 * Wraps an existing [WebSocket.Factory] to mirror WebSocket activity to the SnapO link.
 */
class SnapOInterceptorWebSocketFactory @JvmOverloads constructor(
    private val delegate: WebSocket.Factory,
    private val textPreviewChars: Int = DefaultTextPreviewChars,
    private val binaryPreviewBytes: Int = DefaultBinaryPreviewBytes,
    dispatcher: CoroutineDispatcher = DefaultDispatcher,
) : WebSocket.Factory {

    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    override fun newWebSocket(request: Request, listener: WebSocketListener): WebSocket {
        val webSocketId = UUID.randomUUID().toString()
        val nowWall = System.currentTimeMillis()
        val nowMono = SystemClock.elapsedRealtimeNanos()

        publish {
            WebSocketWillOpen(
                id = webSocketId,
                tWallMs = nowWall,
                tMonoNs = nowMono,
                url = request.url.toString(),
                headers = request.headers.toHeaderList(),
            )
        }

        val interceptingListener = InterceptingListener(webSocketId, listener)
        val realWebSocket = delegate.newWebSocket(request, interceptingListener)
        return InterceptedWebSocket(webSocketId, realWebSocket)
            .also { interceptingListener.interceptedWebSocket = it }
    }

    private inline fun publish(crossinline builder: () -> SnapONetRecord) {
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

    private inner class InterceptedWebSocket(
        private val id: String,
        private val delegate: WebSocket,
    ) : WebSocket {
        override fun request(): Request = delegate.request()

        override fun queueSize(): Long = delegate.queueSize()

        override fun send(text: String): Boolean {
            val encoded = text.encodeToByteArray()
            val preview = textPreview(text)
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            var result = false
            try {
                result = delegate.send(text)
                return result
            } finally {
                publish {
                    WebSocketMessageSent(
                        id = id,
                        tWallMs = nowWall,
                        tMonoNs = nowMono,
                        opcode = "text",
                        preview = preview,
                        payloadSize = encoded.size.toLong(),
                        enqueued = result,
                    )
                }
            }
        }

        override fun send(bytes: ByteString): Boolean {
            val preview = binaryPreview(bytes)
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            var result = false
            try {
                result = delegate.send(bytes)
                return result
            } finally {
                publish {
                    WebSocketMessageSent(
                        id = id,
                        tWallMs = nowWall,
                        tMonoNs = nowMono,
                        opcode = "binary",
                        preview = preview,
                        payloadSize = bytes.size.toLong(),
                        enqueued = result,
                    )
                }
            }
        }

        override fun close(code: Int, reason: String?): Boolean {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            var result = false
            try {
                result = delegate.close(code, reason)
                return result
            } finally {
                publish {
                    WebSocketCloseRequested(
                        id = id,
                        tWallMs = nowWall,
                        tMonoNs = nowMono,
                        code = code,
                        reason = reason,
                        initiated = "client",
                        accepted = result,
                    )
                }
            }
        }

        override fun cancel() {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            try {
                delegate.cancel()
            } finally {
                publish {
                    WebSocketCancelled(
                        id = id,
                        tWallMs = nowWall,
                        tMonoNs = nowMono,
                    )
                }
            }
        }
    }

    private inner class InterceptingListener(
        private val id: String,
        private val downstream: WebSocketListener,
    ) : WebSocketListener() {

        var interceptedWebSocket: WebSocket? = null

        override fun onOpen(webSocket: WebSocket, response: Response) {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            publish {
                WebSocketOpened(
                    id = id,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    code = response.code,
                    headers = response.headers.toHeaderList(),
                )
            }
            downstream.onOpen(interceptedWebSocket ?: webSocket, response)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            val preview = textPreview(text)
            val payloadSize = text.encodeToByteArray().size.toLong()
            publish {
                WebSocketMessageReceived(
                    id = id,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    opcode = "text",
                    preview = preview,
                    payloadSize = payloadSize,
                )
            }
            downstream.onMessage(interceptedWebSocket ?: webSocket, text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            val preview = binaryPreview(bytes)
            publish {
                WebSocketMessageReceived(
                    id = id,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    opcode = "binary",
                    preview = preview,
                    payloadSize = bytes.size.toLong(),
                )
            }
            downstream.onMessage(interceptedWebSocket ?: webSocket, bytes)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            publish {
                WebSocketClosing(
                    id = id,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    code = code,
                    reason = reason.ifEmpty { null },
                )
            }
            downstream.onClosing(interceptedWebSocket ?: webSocket, code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            publish {
                WebSocketClosed(
                    id = id,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    code = code,
                    reason = reason.ifEmpty { null },
                )
            }
            downstream.onClosed(interceptedWebSocket ?: webSocket, code, reason)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            publish {
                WebSocketFailed(
                    id = id,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    errorKind = t.javaClass.simpleName.ifEmpty { t.javaClass.name },
                    message = t.message,
                )
            }
            downstream.onFailure(interceptedWebSocket ?: webSocket, t, response)
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

    private fun textPreview(text: String): String? {
        if (textPreviewChars <= 0) return null
        return if (text.length <= textPreviewChars) {
            text
        } else {
            text.substring(0, textPreviewChars)
        }
    }

    private fun binaryPreview(bytes: ByteString): String? {
        if (binaryPreviewBytes <= 0) return null
        val limit = min(bytes.size, binaryPreviewBytes)
        val slice = if (bytes.size <= limit) bytes else bytes.substring(0, limit)
        return slice.base64()
    }
}

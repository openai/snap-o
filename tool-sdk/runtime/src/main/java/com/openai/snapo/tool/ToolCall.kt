package com.openai.snapo.tool

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.IOException
import java.io.OutputStream
import kotlin.coroutines.CoroutineContext
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** One request and its response. A handler may send exactly one response. */
class ToolCall internal constructor(
    val request: ToolHttpRequest,
    private val connection: ToolConnection,
    private val headers: Map<String, String>,
    private val onStreaming: () -> Unit,
) {
    var pathParameters: Map<String, String> = emptyMap()
        internal set
    internal var responseStarted = false
        private set

    @Volatile internal var writeStartedNs = 0L
        private set

    fun respondJson(json: String, statusCode: Int = 200) = respond(ToolHttpResponse.json(json, statusCode))
    fun respondText(text: String, statusCode: Int = 200) = respond(ToolHttpResponse.text(text, statusCode))
    fun respondNoContent() = respond(ToolHttpResponse(204, byteArrayOf()))

    fun respond(response: ToolHttpResponse, headers: Map<String, String> = emptyMap()) {
        beginResponse()
        writing { response.write(connection.output, this.headers + headers) }
    }

    /** A finite response of unknown size. Each write becomes an HTTP chunk. */
    suspend fun respondStream(
        contentType: String,
        statusCode: Int = 200,
        headers: Map<String, String> = emptyMap(),
        block: suspend ToolResponseStream.() -> Unit,
    ) {
        startStream(contentType, statusCode, headers, chunked = true)
        ToolResponseStream(this, connection.output, true).block()
        writing {
            connection.output.write("0\r\n\r\n".toByteArray(Charsets.US_ASCII))
            connection.output.flush()
        }
    }

    /** Heartbeats and child coroutines end with the session. Set heartbeatInterval to null to disable heartbeats. */
    suspend fun respondSse(
        statusCode: Int = 200,
        headers: Map<String, String> = emptyMap(),
        chunked: Boolean = true,
        heartbeatInterval: Duration? = 30.seconds,
        block: suspend ToolSseSession.() -> Unit,
    ) = coroutineScope {
        require(heartbeatInterval == null || heartbeatInterval.isPositive() && heartbeatInterval.isFinite()) {
            "Heartbeat interval must be positive and finite, or null"
        }
        onStreaming()
        startStream("text/event-stream; charset=utf-8", statusCode, headers, chunked)
        val scope = this
        val disconnect = launch(Dispatchers.IO) {
            try {
                connection.input.read()
            } catch (_: IOException) {
                // EOF and socket errors both end the response and its producer.
            } finally {
                runCatching { connection.close() }
                scope.cancel()
            }
        }
        try {
            coroutineScope {
                val session =
                    ToolSseSession(this, this@ToolCall, connection.output, chunked, connection::close)
                if (heartbeatInterval != null) {
                    launch {
                        while (isActive) {
                            delay(heartbeatInterval)
                            session.heartbeat()
                        }
                    }
                }
                try {
                    session.block()
                } finally {
                    coroutineContext.cancelChildren()
                }
            }
            if (chunked) {
                writing {
                    connection.output.write("0\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    connection.output.flush()
                }
            }
        } finally {
            runCatching { connection.close() }
            disconnect.cancel()
            coroutineContext.cancelChildren()
        }
    }

    private fun startStream(contentType: String, statusCode: Int, headers: Map<String, String>, chunked: Boolean) {
        beginResponse()
        writing {
            ToolHttpResponse.writeHead(
                connection.output,
                statusCode,
                this.headers + headers + mapOf("Content-Type" to contentType, "Connection" to "close") +
                    if (chunked) mapOf("Transfer-Encoding" to "chunked") else emptyMap(),
            )
            connection.output.flush()
        }
    }

    private fun beginResponse() {
        check(!responseStarted) { "Response already started" }
        responseStarted = true
    }

    internal fun writing(write: () -> Unit) {
        writeStartedNs = System.nanoTime()
        try { write() } finally { writeStartedNs = 0 }
    }
}

/** Writes serialized bytes without choosing a serializer or retaining an event queue. */
open class ToolResponseStream internal constructor(
    private val call: ToolCall,
    private val output: OutputStream,
    private val chunked: Boolean,
) {
    @Synchronized
    fun write(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        call.writing {
            if (chunked) output.write("${bytes.size.toString(16)}\r\n".toByteArray(Charsets.US_ASCII))
            output.write(bytes)
            if (chunked) output.write("\r\n".toByteArray(Charsets.US_ASCII))
            output.flush()
        }
    }
}

class ToolSseSession internal constructor(
    scope: CoroutineScope,
    val call: ToolCall,
    output: OutputStream,
    chunked: Boolean,
    private val closeConnection: () -> Unit,
) : ToolResponseStream(call, output, chunked), CoroutineScope {
    override val coroutineContext: CoroutineContext = scope.coroutineContext
    fun send(data: String, event: String? = null, id: String? = null) = write(ToolSse.event(data, event, id))
    fun heartbeat() = write(ToolSse.heartbeat())
    fun close() {
        runCatching { closeConnection() }
        cancel()
    }
}

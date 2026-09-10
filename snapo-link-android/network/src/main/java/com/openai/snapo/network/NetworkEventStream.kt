package com.openai.snapo.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.InputStream
import java.io.OutputStream

/** One bounded SSE response. Its socket also defines the interception owner's lifetime. */
internal class NetworkEventStream(private val closeConnection: () -> Unit) {
    private val lock = Any()
    private val events = Channel<ByteArray>(512)
    private var queuedBytes = 0

    @Volatile
    var isClosed = false
        private set

    @Volatile
    private var writeStartedNs = 0L

    @Volatile
    private var isServing = false

    fun offer(event: ByteArray): Boolean {
        val accepted = synchronized(lock) {
            if (isClosed || queuedBytes.toLong() + event.size > MaxQueuedBytes) {
                false
            } else if (events.trySend(event).isSuccess) {
                queuedBytes += event.size
                true
            } else {
                false
            }
        }
        if (!accepted) close()
        return accepted
    }

    fun close() {
        synchronized(lock) {
            if (isClosed) return
            isClosed = true
            events.cancel()
        }
        if (isServing) runCatching(closeConnection)
    }

    suspend fun serve(
        input: InputStream,
        output: OutputStream,
        location: String? = null,
        headers: String = "",
    ) = coroutineScope {
        isServing = true
        if (isClosed) {
            closeConnection()
            return@coroutineScope
        }
        val disconnect = launch(Dispatchers.IO) {
            try {
                input.read()
            } finally {
                close()
            }
        }
        val watchdog = launch(Dispatchers.Default) {
            while (isActive && !isClosed) {
                delay(1000)
                val started = writeStartedNs
                if (started != 0L && System.nanoTime() - started > WriteTimeoutNs) close()
            }
        }
        try {
            val status = if (location == null) "200 OK" else "201 Created\r\nLocation: $location"
            write(output, ("HTTP/1.1 $status\r\n" + headers + EventStreamHeaders).toByteArray(Charsets.US_ASCII))
            while (!isClosed) {
                val event = withTimeoutOrNull(10_000) { events.receive() }
                if (event != null) synchronized(lock) { queuedBytes -= event.size }
                writeChunk(output, event ?: Heartbeat)
            }
        } finally {
            close()
            disconnect.cancel()
            watchdog.cancel()
        }
    }

    private fun writeChunk(output: OutputStream, bytes: ByteArray) {
        writeStartedNs = System.nanoTime()
        try {
            output.write("${bytes.size.toString(16)}\r\n".toByteArray(Charsets.US_ASCII))
            output.write(bytes)
            output.write("\r\n".toByteArray(Charsets.US_ASCII))
            output.flush()
        } finally {
            writeStartedNs = 0
        }
    }

    private fun write(output: OutputStream, bytes: ByteArray) {
        writeStartedNs = System.nanoTime()
        try {
            output.write(bytes)
            output.flush()
        } finally {
            writeStartedNs = 0
        }
    }
}

internal fun networkSseEvent(message: CdpMessage): ByteArray {
    val text = ProtocolJson.encodeToString(CdpMessage.serializer(), message)
    return sseEvent(text, sequence = message.snapoSequence)
}

internal fun sseEvent(text: String, event: String? = null, sequence: Long? = null): ByteArray {
    val data = text.toByteArray(Charsets.UTF_8)
    require(data.size <= MaxNetworkRecordBytes) { "Event is too large" }
    val prefix = (event?.let { "event: $it\n" } ?: "") +
        (sequence?.let { "id: $it\n" } ?: "") + "data: "
    return prefix.toByteArray(Charsets.US_ASCII) + data + "\n\n".toByteArray(Charsets.US_ASCII)
}

private const val MaxQueuedBytes = 32 * 1024 * 1024
private const val WriteTimeoutNs = 5_000_000_000L
private val Heartbeat = ": keep-alive\n\n".toByteArray(Charsets.US_ASCII)
private const val EventStreamHeaders =
    "Content-Type: text/event-stream; charset=utf-8\r\n" +
        "Transfer-Encoding: chunked\r\nConnection: close\r\nCache-Control: no-store\r\nVary: Accept, Origin\r\n\r\n"

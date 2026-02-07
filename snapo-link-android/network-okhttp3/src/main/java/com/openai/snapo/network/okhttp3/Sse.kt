package com.openai.snapo.network.okhttp3

import android.os.SystemClock
import com.openai.snapo.network.record.NetworkEventRecord
import com.openai.snapo.network.record.ResponseStreamClosed
import com.openai.snapo.network.record.ResponseStreamEvent
import okhttp3.MediaType
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.Source
import okio.buffer
import java.nio.charset.Charset
import java.util.ArrayList
import java.util.concurrent.atomic.AtomicBoolean

internal class StreamingResponseRelayBody(
    private val delegate: ResponseBody,
    requestId: String,
    charset: Charset,
    onRecord: ResponseStreamListener,
) : ResponseBody() {

    private val relay = ResponseStreamRelay(onRecord, requestId, charset)

    private val bufferedSource: BufferedSource by lazy {
        relay.wrapSource(delegate.source()).buffer()
    }

    override fun contentType(): MediaType? = delegate.contentType()

    override fun contentLength(): Long = delegate.contentLength()

    override fun source(): BufferedSource = bufferedSource

    override fun close() {
        try {
            bufferedSource.close()
        } finally {
            relay.onClosed(null)
        }
    }
}

internal fun interface ResponseStreamListener {
    fun onResponseStreamRecord(recordBuilder: () -> NetworkEventRecord)
}

private class ResponseStreamRelay(
    private val listener: ResponseStreamListener,
    private val requestId: String,
    charset: Charset,
) {
    private val closed = AtomicBoolean(false)
    private val parser = SseBuffer(charset)
    private var nextSequence: Long = 0L
    private var totalBytes: Long = 0L

    fun wrapSource(upstream: Source): Source {
        return object : ForwardingSource(upstream) {
            override fun read(sink: Buffer, byteCount: Long): Long {
                return runCatching {
                    val read = super.read(sink, byteCount)
                    if (read > 0) {
                        val copy = Buffer()
                        sink.copyTo(copy, sink.size - read, read)
                        handleBytes(copy.readByteArray())
                    } else if (read == -1L) {
                        onClosed(null)
                    }
                    read
                }.onFailure { error ->
                    onClosed(error)
                }.getOrThrow()
            }

            override fun close() {
                try {
                    super.close()
                } finally {
                    onClosed(null)
                }
            }
        }
    }

    private fun handleBytes(bytes: ByteArray) {
        val events = synchronized(this) {
            totalBytes += bytes.size
            parser.append(bytes).map { raw ->
                val sequence = ++nextSequence
                raw.toParsedSseEvent(sequence)
            }
        }
        publishEvents(events)
    }

    fun onClosed(error: Throwable?) {
        if (!closed.compareAndSet(false, true)) return
        val tailEvents = synchronized(this) {
            parser.drainRemaining().map { raw ->
                val sequence = ++nextSequence
                raw.toParsedSseEvent(sequence)
            }
        }
        publishEvents(tailEvents)

        val nowWall = System.currentTimeMillis()
        val nowMono = SystemClock.elapsedRealtimeNanos()
        listener.onResponseStreamRecord {
            ResponseStreamClosed(
                id = requestId,
                tWallMs = nowWall,
                tMonoNs = nowMono,
                reason = if (error == null) "completed" else "error",
                message = error?.message ?: error?.javaClass?.simpleName,
                totalEvents = nextSequence,
                totalBytes = totalBytes,
            )
        }
    }

    private fun publishEvents(events: List<ParsedSseEvent>) {
        for (event in events) {
            val nowWall = System.currentTimeMillis()
            val nowMono = SystemClock.elapsedRealtimeNanos()
            listener.onResponseStreamRecord {
                ResponseStreamEvent(
                    id = requestId,
                    tWallMs = nowWall,
                    tMonoNs = nowMono,
                    sequence = event.sequence,
                    raw = event.raw,
                )
            }
        }
    }
}

private class SseBuffer(private val charset: Charset) {
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

private data class ParsedSseEvent(
    val sequence: Long,
    val raw: String,
)

private fun String.toParsedSseEvent(sequence: Long): ParsedSseEvent = ParsedSseEvent(
    sequence = sequence,
    raw = this,
)

private fun ByteArray.toNormalizedString(charset: Charset): String {
    val raw = String(this, charset)
    if (raw.indexOf('\r') == -1) return raw
    return raw.replace("\r\n", "\n").replace('\r', '\n')
}

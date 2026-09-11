package com.openai.snapo.network

import com.openai.snapo.plugin.PluginSse
import com.openai.snapo.plugin.PluginSseSession
import kotlinx.coroutines.channels.Channel

/** One bounded SSE response. Its socket also defines the interception owner's lifetime. */
internal class NetworkEventStream {
    private val lock = Any()
    private val events = Channel<ByteArray>(512)
    private var queuedBytes = 0

    @Volatile
    var isClosed = false
        private set

    @Volatile
    private var session: PluginSseSession? = null

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
        session?.close()
    }

    suspend fun serve(session: PluginSseSession) {
        this.session = session
        if (isClosed) {
            session.close()
            return
        }
        try {
            while (!isClosed) {
                val event = events.receive()
                synchronized(lock) { queuedBytes -= event.size }
                session.write(event)
            }
        } finally {
            close()
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
    return PluginSse.event(text, event, sequence?.toString())
}

private const val MaxQueuedBytes = 32 * 1024 * 1024

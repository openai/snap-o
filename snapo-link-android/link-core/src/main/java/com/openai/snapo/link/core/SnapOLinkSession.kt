package com.openai.snapo.link.core

import android.net.LocalSocket
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.selects.select
import kotlinx.serialization.decodeFromString
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

internal class SnapOLinkSession(
    val id: Long,
    private val socket: LocalSocket,
    private val context: SnapOLinkContext,
    private val scope: CoroutineScope,
) {
    private val writer = BufferedWriter(OutputStreamWriter(socket.outputStream, StandardCharsets.UTF_8))
    private val highPriorityQueue = Channel<LinkRecord>(capacity = HighPriorityQueueCapacity)
    private val lowPriorityQueue = Channel<LowPriorityRecord>(capacity = LowPriorityQueueCapacity)

    @Volatile
    private var writerJob: Job? = null

    @Volatile
    private var lastHighPriorityEmissionMs: Long = 0L

    @Volatile
    var attachedFeatures: Map<String, SnapOLinkFeature> = emptyMap()

    @Volatile
    private var sessionState: SnapOLinkSessionState = SnapOLinkSessionState.CONNECTING

    private val openedFeatures = ConcurrentHashMap.newKeySet<String>()

    private val closed = AtomicBoolean(false)
    private val lowPriorityDroppedCount = AtomicLong(0L)

    @Volatile
    private var onCloseListener: ((SnapOLinkSession) -> Unit)? = null

    val state: SnapOLinkSessionState
        get() = sessionState

    suspend fun run(): ClientHandshakeResult {
        val handshake = performClientHandshake()
        if (handshake is ClientHandshakeResult.Rejected) {
            close()
            return handshake
        }

        if (!writeHandshake(context.buildHello(), context.latestAppIcon())) {
            close()
            return ClientHandshakeResult.Rejected("handshake write failure")
        }

        sessionState = SnapOLinkSessionState.ACTIVE
        attachFeatures(context.snapshotFeatures())
        startWriter()

        if (!sendHighPriority(ReplayComplete())) {
            close()
            return ClientHandshakeResult.Accepted
        }

        try {
            tailLines { line -> handleHostMessage(line) }
        } finally {
            close()
        }
        return ClientHandshakeResult.Accepted
    }

    fun sendHighPriority(payload: LinkRecord): Boolean {
        if (!isReady()) return false
        val result = highPriorityQueue.trySend(payload)
        if (result.isSuccess) return true
        if (result.isClosed) return false
        scope.launch {
            try {
                highPriorityQueue.send(payload)
            } catch (_: Throwable) {
            }
        }
        return true
    }

    fun sendLowPriority(payload: LinkRecord): LowPrioritySendResult {
        if (!isReady()) return LowPrioritySendResult.SESSION_NOT_READY
        val item = LowPriorityRecord(payload, SystemClock.elapsedRealtime())
        val result = lowPriorityQueue.trySend(item)
        if (result.isSuccess) return LowPrioritySendResult.SENT
        if (result.isClosed) return LowPrioritySendResult.SESSION_NOT_READY
        lowPriorityDroppedCount.incrementAndGet()
        return LowPrioritySendResult.DROPPED_QUEUE_FULL
    }

    fun lowPriorityDroppedCount(): Long = lowPriorityDroppedCount.get()

    fun markClosed(): Boolean = closed.compareAndSet(false, true)

    fun isClosed(): Boolean = closed.get()

    fun close() {
        if (!markClosed()) return
        sessionState = SnapOLinkSessionState.CLOSED
        writerJob?.cancel()
        writerJob = null
        highPriorityQueue.close()
        lowPriorityQueue.close()
        attachedFeatures.values.forEach { it.onClientDisconnected(id) }
        attachedFeatures = emptyMap()
        openedFeatures.clear()
        closeQuietly()
        onCloseListener?.invoke(this)
    }

    private fun writeHandshake(hello: Hello, icon: AppIcon?): Boolean {
        if (isClosed()) return false
        if (!writeLine(hello)) return false
        markHighPriorityEmission()
        if (icon != null) {
            if (!writeLine(icon)) return false
            markHighPriorityEmission()
        }
        return true
    }

    private suspend fun tailLines(onLine: suspend (String) -> Unit) {
        val reader = BufferedReader(InputStreamReader(socket.inputStream, StandardCharsets.UTF_8))
        while (true) {
            val line = try {
                reader.readLine()
            } catch (_: Throwable) {
                null
            }
            if (line == null) break
            val trimmed = line.trimEnd('\r')
            if (trimmed.isNotEmpty()) {
                onLine(trimmed)
            }
        }
    }

    private fun attachFeatures(features: List<SnapOLinkFeature>) {
        val attached = LinkedHashMap<String, SnapOLinkFeature>(features.size)
        for (feature in features) {
            attached[feature.featureId] = feature
        }
        attachedFeatures = attached
    }

    private suspend fun handleHostMessage(rawLine: String) {
        val message = try {
            Ndjson.decodeFromString(HostMessage.serializer(), rawLine)
        } catch (_: Throwable) {
            return
        }
        when (message) {
            is FeatureOpened -> handleFeatureOpened(message)
        }
    }

    private suspend fun handleFeatureOpened(message: FeatureOpened) {
        val feature = attachedFeatures[message.feature] ?: return
        if (!openedFeatures.add(message.feature)) return
        feature.onFeatureOpened(id)
    }

    fun isFeatureOpened(featureId: String): Boolean =
        openedFeatures.contains(featureId)

    private fun performClientHandshake(): ClientHandshakeResult {
        return try {
            val outcome = readClientHello()
            if (outcome == ClientHelloToken) {
                ClientHandshakeResult.Accepted
            } else {
                ClientHandshakeResult.Rejected("unexpected handshake token")
            }
        } catch (_: SocketTimeoutException) {
            ClientHandshakeResult.Rejected("handshake timeout")
        } catch (ioe: IOException) {
            ClientHandshakeResult.Rejected(ioe.localizedMessage ?: "handshake failure")
        }
    }

    private fun readClientHello(): String {
        socket.soTimeout = ClientHelloTimeoutMs
        val input = socket.inputStream
        val buffer = ByteArrayOutputStream()
        try {
            while (buffer.size() <= ClientHelloMaxBytes) {
                val value = input.read()
                if (value == -1) {
                    throw IOException("client handshake closed without data")
                }
                if (value == '\n'.code) {
                    val raw = buffer.toString(StandardCharsets.UTF_8.name())
                    return raw.trimEnd('\r')
                }
                buffer.write(value)
            }
            throw IOException("client handshake exceeded $ClientHelloMaxBytes bytes")
        } finally {
            socket.soTimeout = 0
        }
    }

    private fun markHighPriorityEmission() {
        lastHighPriorityEmissionMs = SystemClock.elapsedRealtime()
    }

    private fun hasRecentHighPriorityEmission(): Boolean {
        val last = lastHighPriorityEmissionMs
        if (last == 0L) return false
        return SystemClock.elapsedRealtime() - last < HighPriorityIdleThresholdMillis
    }

    private fun writeLine(payload: LinkRecord): Boolean {
        try {
            writer.write(Ndjson.encodeToString(LinkRecord.serializer(), payload))
            writer.write("\n")
            writer.flush()
            return true
        } catch (_: Throwable) {
            try {
                writer.close()
            } catch (_: Throwable) {
            }
            return false
        }
    }

    private fun startWriter() {
        if (writerJob != null || isClosed()) return
        writerJob = scope.launch(Dispatchers.IO) { writerLoop() }
    }

    private suspend fun writerLoop() {
        var pendingLow: LowPriorityRecord? = null
        while (isReady()) {
            when (val action = nextWriterAction(pendingLow)) {
                is WriterAction.SendHigh -> {
                    if (!writeHighOrClose(action.record)) return
                    pendingLow = action.pendingLow
                }

                is WriterAction.SendLow -> {
                    if (!writeLowOrClose(action.record)) return
                    pendingLow = null
                }

                is WriterAction.BufferLow -> pendingLow = action.record
                WriterAction.Closed -> return
            }
        }
    }

    private suspend fun nextWriterAction(pendingLow: LowPriorityRecord?): WriterAction {
        highPriorityQueue.tryReceive().getOrNull()?.let {
            return WriterAction.SendHigh(it, pendingLow)
        }

        val low = pendingLow ?: lowPriorityQueue.tryReceive().getOrNull()
        if (low != null) {
            val incomingHigh = if (shouldDeferLow(low)) waitForHighPriority() else null
            return if (incomingHigh != null) {
                WriterAction.SendHigh(incomingHigh, low)
            } else {
                WriterAction.SendLow(low)
            }
        }

        return when (val next = awaitNextRecord()) {
            is QueueItem.High -> WriterAction.SendHigh(next.record, null)
            is QueueItem.Low -> WriterAction.BufferLow(next.record)
            QueueItem.Closed -> WriterAction.Closed
        }
    }

    private fun writeHighOrClose(record: LinkRecord): Boolean {
        if (!writeLine(record)) {
            close()
            return false
        }
        markHighPriorityEmission()
        return true
    }

    private fun writeLowOrClose(record: LowPriorityRecord): Boolean {
        if (!writeLine(record.record)) {
            close()
            return false
        }
        return true
    }

    private fun shouldDeferLow(record: LowPriorityRecord): Boolean {
        if (!hasRecentHighPriorityEmission()) return false
        val elapsed = SystemClock.elapsedRealtime() - record.enqueuedAtMs
        return elapsed < MaxLowPriorityDeferMillis
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun waitForHighPriority(): LinkRecord? =
        select {
            highPriorityQueue.onReceiveCatching { result -> result.getOrNull() }
            onTimeout(LowPriorityRetryDelayMillis) { null }
        }

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun awaitNextRecord(): QueueItem =
        select {
            highPriorityQueue.onReceiveCatching { result ->
                result.getOrNull()?.let { QueueItem.High(it) } ?: QueueItem.Closed
            }
            lowPriorityQueue.onReceiveCatching { result ->
                result.getOrNull()?.let { QueueItem.Low(it) } ?: QueueItem.Closed
            }
        }

    private sealed interface WriterAction {
        data class SendHigh(val record: LinkRecord, val pendingLow: LowPriorityRecord?) : WriterAction
        data class SendLow(val record: LowPriorityRecord) : WriterAction
        data class BufferLow(val record: LowPriorityRecord) : WriterAction
        object Closed : WriterAction
    }

    private fun closeQuietly() {
        try {
            writer.close()
        } catch (_: Throwable) {
        }
        try {
            socket.close()
        } catch (_: Throwable) {
        }
    }

    fun setOnCloseListener(listener: (SnapOLinkSession) -> Unit) {
        onCloseListener = listener
        if (isClosed()) {
            listener(this)
        }
    }

    private fun isReady(): Boolean =
        !isClosed() && sessionState == SnapOLinkSessionState.ACTIVE

    enum class LowPrioritySendResult {
        SENT,
        DROPPED_QUEUE_FULL,
        SESSION_NOT_READY,
    }
}

internal sealed interface ClientHandshakeResult {
    object Accepted : ClientHandshakeResult
    data class Rejected(val reason: String) : ClientHandshakeResult
}

internal enum class SnapOLinkSessionState {
    CONNECTING,
    ACTIVE,
    CLOSED,
}

private const val ClientHelloToken = "HelloSnapO"
private const val ClientHelloTimeoutMs = 1_000
private const val ClientHelloMaxBytes = 4 * 1024
private const val HighPriorityIdleThresholdMillis = 150L
private const val LowPriorityRetryDelayMillis = 50L
private const val MaxLowPriorityDeferMillis = 2_000L
private const val HighPriorityQueueCapacity = 512
private const val LowPriorityQueueCapacity = 256

private data class LowPriorityRecord(
    val record: LinkRecord,
    val enqueuedAtMs: Long,
)

private sealed interface QueueItem {
    data class High(val record: LinkRecord) : QueueItem
    data class Low(val record: LowPriorityRecord) : QueueItem
    object Closed : QueueItem
}

package com.openai.snapo.link.core

import android.app.Application
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.core.graphics.createBitmap
import androidx.core.graphics.scale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.OutputStreamWriter
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.ArrayList
import java.util.Collections
import java.util.IdentityHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext

/**
 * App-side server that accepts arbitrary SnapONetRecord events,
 * buffers the last [SnapONetConfig.bufferWindow], and streams them to a single desktop client.
 *
 * Transport:
 * ABSTRACT local UNIX domain socket → adb forward tcp:PORT localabstract:snapo_server_$pid
 */
class SnapOLinkServer(
    private val app: Application,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val config: SnapONetConfig = SnapONetConfig(),
) : Closeable {

    /** Name visible to `adb shell cat /proc/net/unix`. */
    val socketName: String = "snapo_server_${Process.myPid()}"

    // --- lifecycle ---
    @Volatile
    private var server: LocalServerSocket? = null

    @Volatile
    private var writerJob: Job? = null

    @Volatile
    private var connectedSink: BufferedWriter? = null

    @Volatile
    private var lastHighPriorityEmissionMs: Long = 0L

    // --- buffering ---
    private val bufferLock = Mutex()
    private val writerLock = Mutex()
    private val eventBuffer: MutableList<SnapONetRecord> = ArrayList()
    private var approxBytes: Long = 0L
    private val openWebSockets: MutableSet<String> = mutableSetOf()
    private val activeResponseStreams: MutableSet<String> = mutableSetOf()

    @Volatile
    private var latestAppIcon: AppIcon? = null

    private val serverStartWallMs = System.currentTimeMillis()
    private val serverStartMonoNs = android.os.SystemClock.elapsedRealtimeNanos()

    fun start() {
        if (!config.allowRelease &&
            app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0
        ) {
            Log.e(
                TAG,
                "Snap-O Link detected in a release build. Link server will NOT start. " +
                    "Release builds should use link-okhttp3-noop instead, " +
                    "or set snapo.allow_release=\"true\" if intentional."
            )
            return
        }

        if (server != null) return

        // Bind in ABSTRACT namespace; collisions are unlikely thanks to PID in the name.
        val server = LocalServerSocket(
            LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT).name
        )
        this.server = server
        writerJob = scope.launch(Dispatchers.IO) { acceptLoop(server) }
        SnapOLink.attach(this)
        scope.launch { emitAppIconIfAvailable() }
    }

    override fun close() {
        writerJob?.cancel()
        writerJob = null
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
        try {
            connectedSink?.close()
        } catch (_: Throwable) {
        }
        connectedSink = null
    }

    /**
     * Publish a record: it’s inserted into the in-memory buffer (kept sorted by wall clock time)
     * and, if a client is connected, streamed immediately as an NDJSON line.
     */
    suspend fun publish(record: SnapONetRecord) {
        // 1) add to buffer (evicting old items)
        bufferLock.withLock {
            appendWithEviction(record)
        }
        // 2) stream live with priority rules
        when (record) {
            is ResponseReceived -> {
                if (record.hasBodyPayload()) {
                    streamLineIfConnected(record.withoutBodyPayload())
                    scheduleResponseBody(record)
                } else {
                    streamLineIfConnected(record)
                }
            }
            else -> streamLineIfConnected(record)
        }
    }

    // ---- internals ----

    private suspend fun acceptLoop(server: LocalServerSocket) {
        while (isActiveSafe()) {
            val socket = try {
                server.accept()
            } catch (_: CancellationException) {
                break
            } catch (_: Throwable) {
                continue
            }

            try {
                if (!processHandshake(socket)) {
                    continue
                }
                if (refuseAdditionalClientIfNeeded(socket)) {
                    continue
                }

                val sink = attachClient(socket)
                val deferredBodies = replayBufferedHistory(sink)
                scheduleDeferredBodies(deferredBodies)
                tailClient(socket)
            } catch (_: CancellationException) {
                break
            } catch (_: Throwable) {
                // swallow and continue accept loop
            } finally {
                cleanupActiveConnection()
                try {
                    socket.close()
                } catch (_: Throwable) {
                }
            }
        }
    }

    private fun processHandshake(socket: LocalSocket): Boolean {
        return when (val handshakeResult = performClientHandshake(socket)) {
            is ClientHandshakeResult.Accepted -> true
            is ClientHandshakeResult.Rejected -> {
                Log.w(TAG, "Rejected client connection for ${handshakeResult.reason}")
                try {
                    socket.close()
                } catch (_: Throwable) {
                }
                false
            }
        }
    }

    private fun refuseAdditionalClientIfNeeded(socket: LocalSocket): Boolean {
        if (!config.singleClientOnly || connectedSink == null) {
            return false
        }

        socket.use { s ->
            val tmpWriter = BufferedWriter(
                OutputStreamWriter(
                    s.outputStream,
                    StandardCharsets.UTF_8
                )
            )
            writeHandshake(tmpWriter)
            tmpWriter.write(Ndjson.encodeToString(ReplayComplete()))
            tmpWriter.write("\n")
            tmpWriter.flush()
        }
        return true
    }

    private fun attachClient(socket: LocalSocket): BufferedWriter {
        val sink = BufferedWriter(OutputStreamWriter(socket.outputStream, StandardCharsets.UTF_8))
        connectedSink = sink
        return sink
    }

    private suspend fun replayBufferedHistory(sink: BufferedWriter): List<ResponseReceived> {
        val deferredBodies = mutableListOf<ResponseReceived>()
        writerLock.withLock {
            writeHandshake(sink)
            val snapshot: List<SnapONetRecord> = bufferLock.withLock { ArrayList(eventBuffer) }
            for (rec in snapshot) {
                if (rec is ResponseReceived && rec.hasBodyPayload()) {
                    writeLine(sink, rec.withoutBodyPayload())
                    deferredBodies.add(rec)
                } else {
                    writeLine(sink, rec)
                }
            }
            writeLine(sink, ReplayComplete())
        }
        return deferredBodies
    }

    private fun scheduleDeferredBodies(deferredBodies: List<ResponseReceived>) {
        deferredBodies.forEachIndexed { index, response ->
            val stagger = ResponseBodyStaggerMillis * index
            scheduleResponseBody(response, ResponseBodyDelayMillis + stagger)
        }
    }

    private fun tailClient(socket: LocalSocket) {
        // Block here reading from the client to detect disconnect; ignore any input.
        val src = socket.inputStream
        val buf = ByteArray(1024)
        while (true) {
            val n = src.read(buf)
            if (n < 0) break
        }
    }

    private fun cleanupActiveConnection() {
        try {
            connectedSink?.close()
        } catch (_: Throwable) {
        }
        connectedSink = null
    }

    private fun appProcessName(): String {
        return try {
            val am =
                app.getSystemService(Application.ACTIVITY_SERVICE) as android.app.ActivityManager
            val pid = Process.myPid()
            am.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName ?: app.packageName
        } catch (_: Throwable) {
            app.packageName
        }
    }

    private fun isActiveSafe(): Boolean =
        (writerJob?.isActive != false)

    private fun writeLine(writer: BufferedWriter, record: SnapONetRecord) {
        try {
            writer.write(Ndjson.encodeToString(SnapONetRecord.serializer(), record))
            writer.write("\n")
            writer.flush()
            markHighPriorityEmission(record)
        } catch (_: Throwable) {
            // connection likely dropped; accept loop will tidy up
            try {
                writer.close()
            } catch (_: Throwable) {
            }
            if (connectedSink === writer) connectedSink = null
        }
    }

    private suspend fun streamLineIfConnected(record: SnapONetRecord) {
        writerLock.withLock {
            val writer = connectedSink ?: return
            writeLine(writer, record)
        }
    }

    private suspend fun streamLowPriority(record: SnapONetRecord) {
        while (coroutineContext.isActive) {
            if (connectedSink == null) return
            if (writerLock.tryLock()) {
                val writer = connectedSink
                if (writer == null) {
                    writerLock.unlock()
                    return
                }
                try {
                    writeLine(writer, record)
                } finally {
                    writerLock.unlock()
                }
                return
            }
            delay(LowPriorityRetryDelayMillis)
        }
    }

    /** Append and evict by window/size/count caps. */
    private fun appendWithEviction(record: SnapONetRecord) {
        insertSorted(record)
        approxBytes += estimateSize(record)
        updateWebSocketStateOnAdd(record)
        updateStreamStateOnAdd(record)

        if (record is TimedRecord) {
            val cutoff = record.tWallMs - config.bufferWindow.inWholeMilliseconds
            evictExpiredRecords(cutoff)
        }

        while (approxBytes > config.maxBufferedBytes && eventBuffer.isNotEmpty()) {
            if (!evictFirstEligible()) break
        }
        while (eventBuffer.size > config.maxBufferedEvents && eventBuffer.isNotEmpty()) {
            if (!evictFirstEligible()) break
        }
    }

    private fun insertSorted(record: SnapONetRecord) {
        val insertIndex = findInsertIndex(record)
        eventBuffer.add(insertIndex, record)
    }

    private fun findInsertIndex(record: SnapONetRecord): Int {
        var low = 0
        var high = eventBuffer.size
        while (low < high) {
            val mid = (low + high) / 2
            val cmp = compareEventTimes(eventBuffer[mid], record)
            if (cmp <= 0) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private fun compareEventTimes(a: SnapONetRecord, b: SnapONetRecord): Int {
        val left = eventTime(a)
        val right = eventTime(b)
        return left.compareTo(right)
    }

    private fun eventTime(record: SnapONetRecord): Long {
        return (record as? TimedRecord)?.tWallMs ?: Long.MAX_VALUE
    }

    private fun evictFirstEligible(): Boolean {
        val iterator = eventBuffer.iterator()
        var evicted = false

        while (iterator.hasNext() && !evicted) {
            val record = iterator.next()

            val shouldRemove = when (record) {
                is RequestWillBeSent -> evictRequestTerminal(record)
                is WebSocketWillOpen -> evictWebSocketConversation(record)
                is WebSocketOpened -> evictWebSocketConversation(record)
                else -> true
            }

            if (shouldRemove) {
                removeRecord(iterator, record)
                evicted = true
            }
        }

        return evicted
    }

    private fun updateWebSocketStateOnAdd(record: SnapONetRecord) {
        when (record) {
            is WebSocketWillOpen -> openWebSockets.add(record.id)
            is WebSocketOpened -> openWebSockets.add(record.id)
            is WebSocketClosed -> openWebSockets.remove(record.id)
            is WebSocketFailed -> openWebSockets.remove(record.id)
            is WebSocketCancelled -> openWebSockets.remove(record.id)
            else -> Unit
        }
    }

    private fun updateWebSocketStateOnRemove(record: SnapONetRecord) {
        when (record) {
            is WebSocketWillOpen -> openWebSockets.remove(record.id)
            is WebSocketOpened -> openWebSockets.remove(record.id)
            else -> Unit
        }
    }

    private fun updateStreamStateOnAdd(record: SnapONetRecord) {
        when (record) {
            is ResponseStreamEvent -> activeResponseStreams.add(record.id)
            is ResponseStreamClosed -> activeResponseStreams.remove(record.id)
            is RequestFailed -> activeResponseStreams.remove(record.id)
            else -> Unit
        }
    }

    private fun updateStreamStateOnRemove(record: SnapONetRecord) {
        when (record) {
            is ResponseStreamClosed -> activeResponseStreams.remove(record.id)
            is RequestFailed -> activeResponseStreams.remove(record.id)
            else -> Unit
        }
    }

    private fun evictRequestTerminal(head: RequestWillBeSent): Boolean {
        val iterator = eventBuffer.iterator()
        var removed = false

        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if (candidate === head) continue
            val isTerminal = when (candidate) {
                is ResponseReceived -> candidate.id == head.id && !activeResponseStreams.contains(head.id)
                is RequestFailed -> candidate.id == head.id
                is ResponseStreamClosed -> candidate.id == head.id
                else -> false
            }
            if (!isTerminal) continue

            iterator.remove()
            subtractApproxBytes(candidate)
            updateWebSocketStateOnRemove(candidate)
            updateStreamStateOnRemove(candidate)
            removeAdditionalRequestRecords(head.id)
            removed = true
            break
        }

        return removed
    }

    private fun evictWebSocketConversation(head: PerWebSocketRecord): Boolean {
        if (openWebSockets.contains(head.id)) {
            return false
        }

        val iterator = eventBuffer.iterator()
        var removedAny = false
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if (candidate === head) continue
            if (candidate is PerWebSocketRecord && candidate.id == head.id) {
                iterator.remove()
                subtractApproxBytes(candidate)
                updateWebSocketStateOnRemove(candidate)
                updateStreamStateOnRemove(candidate)
                removedAny = true
            }
        }
        return removedAny
    }

    private data class RequestPruneState(
        var start: RequestWillBeSent? = null,
        var terminal: SnapONetRecord? = null,
        val oldEvents: MutableList<ResponseStreamEvent> = mutableListOf(),
        val oldRecords: MutableList<SnapONetRecord> = mutableListOf(),
        var hasRecentRecords: Boolean = false,
    )

    private data class WebSocketPruneState(
        val startRecords: MutableList<PerWebSocketRecord> = mutableListOf(),
        var terminal: PerWebSocketRecord? = null,
        val oldRecords: MutableList<PerWebSocketRecord> = mutableListOf(),
        var hasRecentRecords: Boolean = false,
    )

    private data class ExpiredRecordPruneState(
        val requestStates: MutableMap<String, RequestPruneState> = mutableMapOf(),
        val webSocketStates: MutableMap<String, WebSocketPruneState> = mutableMapOf(),
        val toRemove: MutableSet<SnapONetRecord> = Collections.newSetFromMap(IdentityHashMap()),
    )

    private fun evictExpiredRecords(cutoff: Long) {
        val state = buildExpiredRecordPruneState(cutoff)
        markRequestRemovals(state)
        markWebSocketRemovals(state)
        removeMarkedRecords(state.toRemove)
    }

    private fun buildExpiredRecordPruneState(cutoff: Long): ExpiredRecordPruneState {
        val state = ExpiredRecordPruneState()
        for (record in eventBuffer) {
            val time = eventTime(record)
            when {
                record is PerRequestRecord -> collectRequestExpiryState(record, time, cutoff, state)
                record is PerWebSocketRecord -> collectWebSocketExpiryState(record, time, cutoff, state)
                time < cutoff -> state.toRemove.add(record)
            }
        }
        return state
    }

    private fun collectRequestExpiryState(
        record: PerRequestRecord,
        time: Long,
        cutoff: Long,
        state: ExpiredRecordPruneState,
    ) {
        val requestState = state.requestStates.getOrPut(record.id) { RequestPruneState() }
        if (time >= cutoff) {
            requestState.hasRecentRecords = true
            return
        }

        when (record) {
            is RequestWillBeSent -> requestState.start = record
            is ResponseStreamEvent -> requestState.oldEvents.add(record)
            is ResponseReceived -> {
                if (!activeResponseStreams.contains(record.id)) {
                    requestState.terminal = record
                }
                requestState.oldRecords.add(record)
            }

            is RequestFailed -> {
                requestState.terminal = record
                requestState.oldRecords.add(record)
            }

            is ResponseStreamClosed -> {
                requestState.terminal = record
                requestState.oldRecords.add(record)
            }
        }
    }

    private fun collectWebSocketExpiryState(
        record: PerWebSocketRecord,
        time: Long,
        cutoff: Long,
        state: ExpiredRecordPruneState,
    ) {
        val webSocketState = state.webSocketStates.getOrPut(record.id) { WebSocketPruneState() }
        if (time >= cutoff) {
            webSocketState.hasRecentRecords = true
            return
        }

        when (record) {
            is WebSocketWillOpen,
            is WebSocketOpened -> webSocketState.startRecords.add(record)

            is WebSocketClosed,
            is WebSocketFailed,
            is WebSocketCancelled -> {
                webSocketState.terminal = record
                webSocketState.oldRecords.add(record)
            }

            else -> webSocketState.oldRecords.add(record)
        }
    }

    private fun markRequestRemovals(state: ExpiredRecordPruneState) {
        for ((id, requestState) in state.requestStates) {
            if (requestState.oldEvents.isNotEmpty()) {
                requestState.oldEvents.forEach(state.toRemove::add)
            }
            val hasRecent = requestState.hasRecentRecords || activeResponseStreams.contains(id)
            if (!hasRecent && requestState.terminal != null) {
                requestState.start?.let(state.toRemove::add)
                requestState.oldRecords.forEach(state.toRemove::add)
            }
        }
    }

    private fun markWebSocketRemovals(state: ExpiredRecordPruneState) {
        for ((id, webSocketState) in state.webSocketStates) {
            val isOpen = openWebSockets.contains(id)
            if (webSocketState.hasRecentRecords || isOpen) {
                webSocketState.oldRecords.forEach(state.toRemove::add)
            } else if (webSocketState.terminal != null) {
                webSocketState.startRecords.forEach(state.toRemove::add)
                webSocketState.oldRecords.forEach(state.toRemove::add)
            }
        }
    }

    private fun removeMarkedRecords(records: MutableSet<SnapONetRecord>) {
        if (records.isEmpty()) return
        val iterator = eventBuffer.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (!records.contains(record)) continue
            removeRecord(iterator, record)
        }
    }

    private fun removeRecord(
        iterator: MutableIterator<SnapONetRecord>,
        record: SnapONetRecord,
    ) {
        iterator.remove()
        subtractApproxBytes(record)
        updateWebSocketStateOnRemove(record)
        updateStreamStateOnRemove(record)
    }

    private fun removeAdditionalRequestRecords(requestId: String) {
        val iterator = eventBuffer.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            when (record) {
                is ResponseReceived -> if (record.id == requestId) {
                    iterator.remove()
                    subtractApproxBytes(record)
                    updateStreamStateOnRemove(record)
                }

                is ResponseStreamEvent -> if (record.id == requestId) {
                    iterator.remove()
                    subtractApproxBytes(record)
                    updateStreamStateOnRemove(record)
                }

                else -> Unit
            }
        }
    }

    private fun markHighPriorityEmission(record: SnapONetRecord) {
        if (!record.isHighPriorityRecord()) return
        lastHighPriorityEmissionMs = SystemClock.elapsedRealtime()
    }

    private fun hasRecentHighPriorityEmission(): Boolean {
        val last = lastHighPriorityEmissionMs
        if (last == 0L) return false
        return SystemClock.elapsedRealtime() - last < HighPriorityIdleThresholdMillis
    }

    private fun SnapONetRecord.isHighPriorityRecord(): Boolean = when (this) {
        is ResponseReceived -> !this.hasBodyPayload()
        else -> true
    }

    private fun ResponseReceived.hasBodyPayload(): Boolean {
        if (!body.isNullOrEmpty()) return true
        if (!bodyPreview.isNullOrEmpty()) return true
        return false
    }

    private fun ResponseReceived.withoutBodyPayload(): ResponseReceived =
        copy(bodyPreview = null, body = null)

    private fun scheduleResponseBody(
        record: ResponseReceived,
        initialDelayMs: Long = ResponseBodyDelayMillis,
    ) {
        scope.launch(Dispatchers.IO) {
            try {
                if (initialDelayMs > 0) {
                    delay(initialDelayMs)
                }
                val deferStart = SystemClock.elapsedRealtime()
                while (hasRecentHighPriorityEmission() && connectedSink != null) {
                    if (SystemClock.elapsedRealtime() - deferStart >= MaxBodyDeferMillis) {
                        break
                    }
                    delay(LowPriorityRetryDelayMillis)
                }
                streamLowPriority(record)
            } catch (t: CancellationException) {
                throw t
            } catch (_: Throwable) {
            }
        }
    }

    private fun subtractApproxBytes(record: SnapONetRecord) {
        approxBytes = (approxBytes - estimateSize(record)).coerceAtLeast(0)
    }

    private fun estimateSize(record: SnapONetRecord): Int {
        return Ndjson.encodeToString(SnapONetRecord.serializer(), record).length
    }

    private suspend fun emitAppIconIfAvailable() {
        val iconEvent = loadAppIconEvent() ?: return
        latestAppIcon = iconEvent
        streamAppIcon(iconEvent)
    }

    private fun performClientHandshake(socket: LocalSocket): ClientHandshakeResult {
        return try {
            val outcome = readClientHello(socket)
            if (outcome == ClientHelloToken) {
                ClientHandshakeResult.Accepted
            } else {
                ClientHandshakeResult.Rejected("unexpected handshake token")
            }
        } catch (_: SocketTimeoutException) {
            ClientHandshakeResult.Rejected("handshake timeout")
        } catch (t: Throwable) {
            ClientHandshakeResult.Rejected(t.localizedMessage ?: "handshake failure")
        }
    }

    private fun readClientHello(socket: LocalSocket): String? {
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

    private fun loadAppIconEvent(): AppIcon? {
        val drawable = try {
            app.packageManager.getApplicationIcon(app.applicationInfo)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        } catch (_: Resources.NotFoundException) {
            return null
        } catch (_: SecurityException) {
            return null
        }

        return try {
            drawableToBitmap(drawable)?.let { bitmap ->
                val scaled = if (bitmap.width == TargetIconSize && bitmap.height == TargetIconSize) {
                    bitmap
                } else {
                    bitmap.scale(TargetIconSize, TargetIconSize)
                }

                val pngData = ByteArrayOutputStream().use { out ->
                    scaled.compress(Bitmap.CompressFormat.PNG, IconPngQuality, out)
                    out.toByteArray()
                }
                if (scaled !== bitmap && !scaled.isRecycled) {
                    scaled.recycle()
                }
                val encoded = Base64.encodeToString(pngData, Base64.NO_WRAP)

                AppIcon(
                    packageName = app.packageName,
                    width = TargetIconSize,
                    height = TargetIconSize,
                    base64Data = encoded,
                )
            }
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun writeHandshake(writer: BufferedWriter) {
        writeLine(
            writer,
            Hello(
                packageName = app.packageName,
                processName = appProcessName(),
                pid = Process.myPid(),
                serverStartWallMs = serverStartWallMs,
                serverStartMonoNs = serverStartMonoNs,
                mode = config.modeLabel,
            )
        )

        latestAppIcon?.let { icon ->
            writeLine(writer, icon)
        }
    }

    private suspend fun streamAppIcon(icon: AppIcon) {
        writerLock.withLock {
            val writer = connectedSink ?: return
            writeLine(writer, icon)
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        if (drawable is BitmapDrawable) {
            return drawable.bitmap
        }
        return renderDrawable(drawable)
    }

    private fun renderDrawable(drawable: Drawable): Bitmap {
        val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: TargetIconSize
        val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: TargetIconSize
        val bitmap = createBitmap(width, height)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }

    companion object {
        fun start(
            application: Application,
            scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            config: SnapONetConfig = SnapONetConfig(),
        ): SnapOLinkServer =
            SnapOLinkServer(application, scope, config)
                .also { it.start() }
    }
}

private const val TAG = "SnapOLink"
private const val TargetIconSize = 96
private const val IconPngQuality = 100
private const val ClientHelloToken = "HelloSnapO"
private const val ClientHelloTimeoutMs = 1_000
private const val ClientHelloMaxBytes = 4 * 1024
private const val ResponseBodyDelayMillis = 200L
private const val ResponseBodyStaggerMillis = 25L
private const val HighPriorityIdleThresholdMillis = 150L
private const val LowPriorityRetryDelayMillis = 50L
private const val MaxBodyDeferMillis = 2_000L

private sealed interface ClientHandshakeResult {
    object Accepted : ClientHandshakeResult
    data class Rejected(val reason: String) : ClientHandshakeResult
}

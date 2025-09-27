package com.openai.snapo.link.core

import android.app.Application
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.util.Base64
import android.util.Log
import androidx.core.graphics.createBitmap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
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

/**
 * App-side server that accepts arbitrary SnapONetRecord events,
 * buffers the last [config.bufferWindowMs], and streams them to a single desktop client.
 *
 * Transport: ABSTRACT local UNIX domain socket → adb forward tcp:PORT localabstract:snapo_server_$pid
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

    // --- buffering ---
    private val bufferLock = Mutex()
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
        server = LocalServerSocket(
            LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT).name
        )
        writerJob = scope.launch(Dispatchers.IO) { acceptLoop(server!!) }
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
        // 2) try to stream live
        streamLineIfConnected(record)
    }

    // ---- internals ----

    private suspend fun acceptLoop(server: LocalServerSocket) {
        while (isActiveSafe()) {
            try {
                val sock: LocalSocket = server.accept()
                when (val handshakeResult = performClientHandshake(sock)) {
                    is ClientHandshakeResult.Accepted -> Unit
                    is ClientHandshakeResult.Rejected -> {
                        Log.w(
                            TAG,
                            "Rejected client connection for ${handshakeResult.reason}"
                        )
                        try {
                            sock.close()
                        } catch (_: Throwable) {
                        }
                        continue
                    }
                }

                if (config.singleClientOnly && connectedSink != null) {
                    // Politely refuse additional clients.
                    sock.use { s ->
                        val tmpWriter = BufferedWriter(
                            OutputStreamWriter(
                                s.outputStream,
                                StandardCharsets.UTF_8
                            )
                        )
                        writeHandshake(tmpWriter)
                        tmpWriter.write(
                            Ndjson.encodeToString(ReplayComplete()),
                        )
                        tmpWriter.write("\n")
                        tmpWriter.flush()
                    }
                    continue
                }

                // Attach as the active client
                connectedSink =
                    BufferedWriter(OutputStreamWriter(sock.outputStream, StandardCharsets.UTF_8))
                val sink = connectedSink!!

                // 1) Hello
                writeHandshake(sink)

                // 2) Snapshot (buffer copy under lock to avoid holding it while writing)
                val snapshot: List<SnapONetRecord> = bufferLock.withLock { ArrayList(eventBuffer) }
                for (rec in snapshot) writeLine(sink, rec)

                // 3) ReplayComplete marker
                writeLine(sink, ReplayComplete())

                // 4) Live tail: just keep the sink around; publish() will write as events arrive.
                // Block here reading from the client to detect disconnect; ignore any input.
                val src = sock.inputStream
                val buf = ByteArray(1024)
                while (true) {
                    val n = src.read(buf)
                    if (n < 0) break
                    // ignore incoming data for v1
                }
            } catch (_: CancellationException) {
                break
            } catch (_: Throwable) {
                // swallow and continue accept loop
            } finally {
                try {
                    connectedSink?.close()
                } catch (_: Throwable) {
                }
                connectedSink = null
            }
        }
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
        } catch (t: Throwable) {
            // connection likely dropped; accept loop will tidy up
            try {
                writer.close()
            } catch (_: Throwable) {
            }
            if (connectedSink === writer) connectedSink = null
        }
    }

    private fun streamLineIfConnected(record: SnapONetRecord) {
        val writer = connectedSink ?: return
        writeLine(writer, record)
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
            if (!evictFirstEligible(null)) break
        }
        while (eventBuffer.size > config.maxBufferedEvents && eventBuffer.isNotEmpty()) {
            if (!evictFirstEligible(null)) break
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

    private fun evictFirstEligible(cutoff: Long?): Boolean {
        val iterator = eventBuffer.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (!isOlderThanCutoff(record, cutoff)) continue

            when (record) {
                is RequestWillBeSent -> {
                    if (!evictRequestTerminal(record, cutoff)) continue
                    removeRecord(iterator, record)
                    return true
                }

                is WebSocketWillOpen -> {
                    if (!evictWebSocketConversation(record, cutoff)) continue
                    removeRecord(iterator, record)
                    return true
                }

                is WebSocketOpened -> {
                    if (!evictWebSocketConversation(record, cutoff)) continue
                    removeRecord(iterator, record)
                    return true
                }

                else -> {
                    removeRecord(iterator, record)
                    return true
                }
            }
        }
        return false
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

    private fun evictRequestTerminal(head: RequestWillBeSent, cutoff: Long?): Boolean {
        val iterator = eventBuffer.iterator()
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

            if (cutoff != null && candidate is TimedRecord && candidate.tWallMs >= cutoff) {
                return false
            }

            iterator.remove()
            subtractApproxBytes(candidate)
            updateWebSocketStateOnRemove(candidate)
            updateStreamStateOnRemove(candidate)
            return true
        }
        return false
    }

    private fun evictWebSocketConversation(head: PerWebSocketRecord, cutoff: Long?): Boolean {
        if (openWebSockets.contains(head.id)) {
            return false
        }

        if (!allWebSocketEventsOlderThanCutoff(head, cutoff)) {
            return false
        }

        val iterator = eventBuffer.iterator()
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if (candidate === head) continue
            if (candidate is PerWebSocketRecord && candidate.id == head.id) {
                iterator.remove()
                subtractApproxBytes(candidate)
                updateWebSocketStateOnRemove(candidate)
                updateStreamStateOnRemove(candidate)
            }
        }
        return true
    }

    private fun evictExpiredRecords(cutoff: Long) {
        val requestStarts = mutableMapOf<String, RequestWillBeSent>()
        val requestTerminals = mutableMapOf<String, SnapONetRecord>()
        val webSocketStarts = mutableMapOf<String, MutableList<PerWebSocketRecord>>()
        val webSocketTerminals = mutableMapOf<String, PerWebSocketRecord>()
        val toRemove: MutableSet<SnapONetRecord> =
            Collections.newSetFromMap(IdentityHashMap<SnapONetRecord, Boolean>())

        for (record in eventBuffer) {
            if (!isOlderThanCutoff(record, cutoff)) continue
            when (record) {
                is RequestWillBeSent -> requestStarts[record.id] = record
                is ResponseReceived -> if (!activeResponseStreams.contains(record.id)) {
                    requestTerminals[record.id] = record
                }
                is RequestFailed -> requestTerminals[record.id] = record
                is ResponseStreamClosed -> requestTerminals[record.id] = record
                is WebSocketWillOpen ->
                    webSocketStarts.getOrPut(record.id) { mutableListOf() }.add(record)
                is WebSocketOpened ->
                    webSocketStarts.getOrPut(record.id) { mutableListOf() }.add(record)
                is WebSocketClosed -> webSocketTerminals[record.id] = record
                is WebSocketFailed -> webSocketTerminals[record.id] = record
                is WebSocketCancelled -> webSocketTerminals[record.id] = record
                else -> toRemove.add(record)
            }
        }

        for ((id, head) in requestStarts) {
            val terminal = requestTerminals[id] ?: continue
            toRemove.add(head)
            toRemove.add(terminal)
        }

        for ((id, headList) in webSocketStarts) {
            val terminal = webSocketTerminals[id] ?: continue
            if (openWebSockets.contains(id)) continue
            toRemove.add(terminal)
            headList.forEach { toRemove.add(it) }
        }

        if (toRemove.isEmpty()) return

        val iterator = eventBuffer.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()
            if (!toRemove.contains(record)) continue
            iterator.remove()
            subtractApproxBytes(record)
            updateWebSocketStateOnRemove(record)
            updateStreamStateOnRemove(record)
        }
    }

    private fun allWebSocketEventsOlderThanCutoff(
        head: PerWebSocketRecord,
        cutoff: Long?,
    ): Boolean {
        cutoff ?: return true
        for (candidate in eventBuffer) {
            if (candidate === head) continue
            if (candidate is PerWebSocketRecord && candidate.id == head.id) {
                if (candidate.tWallMs >= cutoff) {
                    return false
                }
            }
        }
        return true
    }

    private fun isOlderThanCutoff(record: SnapONetRecord, cutoff: Long?): Boolean {
        cutoff ?: return true
        return eventTime(record) < cutoff
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

    private fun subtractApproxBytes(record: SnapONetRecord) {
        approxBytes = (approxBytes - estimateSize(record)).coerceAtLeast(0)
    }

    private fun estimateSize(record: SnapONetRecord): Int {
        return Ndjson.encodeToString(SnapONetRecord.serializer(), record).length
    }

    private fun emitAppIconIfAvailable() {
        try {
            val iconEvent = loadAppIconEvent() ?: return
            latestAppIcon = iconEvent
            streamAppIcon(iconEvent)
        } catch (_: Throwable) {
        }
    }

    private fun performClientHandshake(socket: LocalSocket): ClientHandshakeResult {
        return try {
            val outcome = readClientHello(socket)
            if (outcome == CLIENT_HELLO_TOKEN) {
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
        socket.soTimeout = CLIENT_HELLO_TIMEOUT_MS
        val input = socket.inputStream
        val buffer = ByteArrayOutputStream()
        return try {
            while (buffer.size() <= CLIENT_HELLO_MAX_BYTES) {
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
            throw IOException("client handshake exceeded $CLIENT_HELLO_MAX_BYTES bytes")
        } finally {
            socket.soTimeout = 0
        }
    }

    private fun loadAppIconEvent(): AppIcon? {
        val pm: PackageManager = app.packageManager
        val drawable: Drawable = try {
            pm.getApplicationIcon(app.applicationInfo)
        } catch (_: Throwable) {
            return null
        }

        val bitmap = drawableToBitmap(drawable) ?: return null
        val scaled = if (bitmap.width == TARGET_ICON_SIZE && bitmap.height == TARGET_ICON_SIZE) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, TARGET_ICON_SIZE, TARGET_ICON_SIZE, true)
        }

        val pngData = ByteArrayOutputStream().use { out ->
            scaled.compress(Bitmap.CompressFormat.PNG, ICON_PNG_QUALITY, out)
            out.toByteArray()
        }
        if (scaled !== bitmap && !scaled.isRecycled) {
            scaled.recycle()
        }
        val encoded = Base64.encodeToString(pngData, Base64.NO_WRAP)

        return AppIcon(
            packageName = app.packageName,
            width = TARGET_ICON_SIZE,
            height = TARGET_ICON_SIZE,
            base64Data = encoded,
        )
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

    private fun streamAppIcon(icon: AppIcon) {
        val writer = connectedSink ?: return
        writeLine(writer, icon)
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        if (drawable is BitmapDrawable) {
            return drawable.bitmap
        }
        return renderDrawable(drawable)
    }

    private fun renderDrawable(drawable: Drawable): Bitmap {
        val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: TARGET_ICON_SIZE
        val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: TARGET_ICON_SIZE
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
private const val TARGET_ICON_SIZE = 96
private const val ICON_PNG_QUALITY = 100
private const val CLIENT_HELLO_TOKEN = "HelloSnapO"
private const val CLIENT_HELLO_TIMEOUT_MS = 1_000
private const val CLIENT_HELLO_MAX_BYTES = 4 * 1024

private sealed interface ClientHandshakeResult {
    object Accepted : ClientHandshakeResult
    data class Rejected(val reason: String) : ClientHandshakeResult
}

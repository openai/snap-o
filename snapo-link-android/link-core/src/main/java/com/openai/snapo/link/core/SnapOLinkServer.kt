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
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import kotlin.coroutines.cancellation.CancellationException
import androidx.core.graphics.createBitmap

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
    private val ring: ArrayDeque<SnapONetRecord> = ArrayDeque()
    private var approxBytes: Long = 0L
    private val openWebSockets: MutableSet<String> = mutableSetOf()

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
     * Publish a record: it’s appended to the in-memory ring and, if a client is connected,
     * streamed immediately as an NDJSON line.
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
                            Ndjson.encodeToString(ReplayComplete(schemaVersion = SCHEMA_VERSION)),
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
                val snapshot: List<SnapONetRecord> = bufferLock.withLock { ArrayList(ring) }
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
        ring.addLast(record)
        approxBytes += Ndjson.encodeToString(record).length // quick estimate; good enough for bounding
        updateWebSocketStateOnAdd(record)

        if (record is TimedRecord) {
            val cutoff = record.tWallMs - config.bufferWindow.inWholeMilliseconds
            while (evictFirstEligible(cutoff)) {
            }
        }

        while (approxBytes > config.maxBufferedBytes && ring.isNotEmpty()) {
            if (!evictFirstEligible(null)) break
        }
        while (ring.size > config.maxBufferedEvents && ring.isNotEmpty()) {
            if (!evictFirstEligible(null)) break
        }
    }

    private fun evictFirstEligible(cutoff: Long?): Boolean {
        val iterator = ring.iterator()
        while (iterator.hasNext()) {
            val record = iterator.next()

            if (cutoff != null) {
                val eventTime = when (record) {
                    is TimedRecord -> record.tWallMs
                    else -> Long.MAX_VALUE
                }
                if (eventTime >= cutoff) continue
            }

            when (record) {
                is WebSocketWillOpen -> continue
                is WebSocketOpened -> continue
                is RequestWillBeSent -> {
                    if (!evictRequestTerminal(record, cutoff)) {
                        continue
                    }
                    iterator.remove()
                    approxBytes -= Ndjson.encodeToString(record).length
                    updateWebSocketStateOnRemove(record)
                    return true
                }

                else -> {
                    iterator.remove()
                    approxBytes -= Ndjson.encodeToString(record).length
                    updateWebSocketStateOnRemove(record)
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

    private fun evictRequestTerminal(head: RequestWillBeSent, cutoff: Long?): Boolean {
        val iterator = ring.iterator()
        while (iterator.hasNext()) {
            val candidate = iterator.next()
            if (candidate === head) continue
            val isTerminal = when (candidate) {
                is ResponseReceived -> candidate.id == head.id
                is RequestFailed -> candidate.id == head.id
                else -> false
            }
            if (!isTerminal) continue

            if (cutoff != null && candidate is TimedRecord && candidate.tWallMs >= cutoff) {
                return false
            }

            iterator.remove()
            approxBytes -= Ndjson.encodeToString(candidate).length
            updateWebSocketStateOnRemove(candidate)
            return true
        }
        return false
    }

    private fun emitAppIconIfAvailable() {
        try {
            val iconEvent = loadAppIconEvent() ?: return
            latestAppIcon = iconEvent
            streamAppIcon(iconEvent)
        } catch (_: Throwable) {
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

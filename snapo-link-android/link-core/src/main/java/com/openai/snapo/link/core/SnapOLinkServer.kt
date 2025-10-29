package com.openai.snapo.link.core

import android.app.Application
import android.content.pm.ApplicationInfo
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.os.SystemClock
import android.util.Log
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
    private val eventBuffer = EventBuffer(config)

    @Volatile
    private var latestAppIcon: AppIcon? = null
    private val appIconProvider = AppIconProvider(app)

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
            eventBuffer.append(record)
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
            val socket = acceptSocketOrNull(server) ?: continue
            handleAcceptedSocket(socket)
        }
    }

    private suspend fun acceptSocketOrNull(server: LocalServerSocket): LocalSocket? =
        try {
            server.accept()
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            null
        }

    private suspend fun handleAcceptedSocket(socket: LocalSocket) {
        val proceed = try {
            processHandshake(socket) && !refuseAdditionalClientIfNeeded(socket)
        } catch (ce: CancellationException) {
            throw ce
        } catch (_: Throwable) {
            false
        }

        try {
            if (proceed) {
                val sink = attachClient(socket)
                val deferredBodies = replayBufferedHistory(sink)
                scheduleDeferredBodies(deferredBodies)
                tailClient(socket)
            }
        } catch (ce: CancellationException) {
            throw ce
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
            val snapshot: List<SnapONetRecord> = bufferLock.withLock { eventBuffer.snapshot() }
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

    private suspend fun emitAppIconIfAvailable() {
        val iconEvent = appIconProvider.loadAppIcon() ?: return
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
        } catch (ioe: IOException) {
            ClientHandshakeResult.Rejected(ioe.localizedMessage ?: "handshake failure")
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

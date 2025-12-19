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
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.serializer
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.OutputStreamWriter
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import kotlin.coroutines.cancellation.CancellationException

/**
 * App-side server that accepts a single desktop client and delegates streaming to features.
 *
 * Transport:
 * ABSTRACT local UNIX domain socket → adb forward tcp:PORT localabstract:snapo_server_$pid
 */
class SnapOLinkServer(
    private val app: Application,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val config: SnapOLinkConfig = SnapOLinkConfig(),
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

    private val writerLock = Mutex()
    private var attachedFeatures: List<SnapOLinkFeature> = emptyList()

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
        cleanupActiveConnection()
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
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
                val writer = attachClient(socket)
                val sink = ServerEventSink()
                writerLock.withLock {
                    writeHandshake(writer)
                }
                attachFeatures(sink)
                sink.sendHighPriority(ReplayComplete())
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

    private suspend fun attachFeatures(sink: LinkEventSink) {
        val features = SnapOLinkRegistry.snapshot()
        attachedFeatures = features
        for (feature in features) {
            feature.onClientConnected(sink)
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
        val features = attachedFeatures
        attachedFeatures = emptyList()
        features.forEach { it.onClientDisconnected() }
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

    private inner class ServerEventSink : LinkEventSink {
        override suspend fun <T> sendHighPriority(payload: T, serializer: SerializationStrategy<T>) {
            sendHighPriorityRecord(payload, serializer)
        }

        override suspend fun <T> sendLowPriority(payload: T, serializer: SerializationStrategy<T>) {
            sendLowPriorityRecord(payload, serializer)
        }
    }

    private fun <T> writeLine(
        writer: BufferedWriter,
        payload: T,
        serializer: SerializationStrategy<T>,
    ): Boolean {
        try {
            writer.write(Ndjson.encodeToString(serializer, payload))
            writer.write("\n")
            writer.flush()
            return true
        } catch (_: Throwable) {
            // connection likely dropped; accept loop will tidy up
            try {
                writer.close()
            } catch (_: Throwable) {
            }
            if (connectedSink === writer) connectedSink = null
            return false
        }
    }

    private suspend fun <T> sendHighPriorityRecord(
        payload: T,
        serializer: SerializationStrategy<T>,
    ) {
        writerLock.withLock {
            val writer = connectedSink ?: return
            if (writeLine(writer, payload, serializer)) {
                markHighPriorityEmission()
            }
        }
    }

    private suspend fun <T> sendLowPriorityRecord(
        payload: T,
        serializer: SerializationStrategy<T>,
    ) {
        val deferStart = SystemClock.elapsedRealtime()
        while (currentCoroutineContext().isActive) {
            if (connectedSink == null) return
            if (hasRecentHighPriorityEmission() &&
                SystemClock.elapsedRealtime() - deferStart < MaxLowPriorityDeferMillis
            ) {
                delay(LowPriorityRetryDelayMillis)
                continue
            }
            if (writerLock.tryLock()) {
                val writer = connectedSink
                if (writer == null) {
                    writerLock.unlock()
                    return
                }
                try {
                    writeLine(writer, payload, serializer)
                } finally {
                    writerLock.unlock()
                }
                return
            }
            delay(LowPriorityRetryDelayMillis)
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
        if (
            writeLine(
                writer,
                Hello(
                    packageName = app.packageName,
                    processName = appProcessName(),
                    pid = Process.myPid(),
                    serverStartWallMs = serverStartWallMs,
                    serverStartMonoNs = serverStartMonoNs,
                    mode = config.modeLabel,
                ),
                serializer(),
            )
        ) {
            markHighPriorityEmission()
        }

        latestAppIcon?.let { icon ->
            if (writeLine(writer, icon, serializer())) {
                markHighPriorityEmission()
            }
        }
    }

    private suspend fun streamAppIcon(icon: AppIcon) {
        writerLock.withLock {
            val writer = connectedSink ?: return
            if (writeLine(writer, icon, serializer())) {
                markHighPriorityEmission()
            }
        }
    }

    companion object {
        fun start(
            application: Application,
            scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            config: SnapOLinkConfig = SnapOLinkConfig(),
        ): SnapOLinkServer =
            SnapOLinkServer(application, scope, config)
                .also { it.start() }
    }
}

private const val TAG = "SnapOLink"
private const val ClientHelloToken = "HelloSnapO"
private const val ClientHelloTimeoutMs = 1_000
private const val ClientHelloMaxBytes = 4 * 1024
private const val HighPriorityIdleThresholdMillis = 150L
private const val LowPriorityRetryDelayMillis = 50L
private const val MaxLowPriorityDeferMillis = 2_000L

private sealed interface ClientHandshakeResult {
    object Accepted : ClientHandshakeResult
    data class Rejected(val reason: String) : ClientHandshakeResult
}

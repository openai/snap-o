package com.openai.snapo.network

import android.app.ActivityManager
import android.app.Application
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets

internal data class NetworkReplaySnapshot(
    val messages: List<CdpMessage>,
    val watermark: Long,
)

internal class NetworkInspectorTransport(
    private val app: Application,
    private val config: NetworkInspectorConfig,
    private val snapshotProvider: suspend () -> NetworkReplaySnapshot,
    private val commandHandler: suspend (CdpMessage) -> CdpMessage?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val appIconProvider: AppIconProvider = AppIconProvider(app),
    private val serverStartWallMs: Long = System.currentTimeMillis(),
    private val serverStartMonoNs: Long = SystemClock.elapsedRealtimeNanos(),
) : Closeable {
    val socketName: String = "snapo_network_${Process.myPid()}"

    @Volatile
    private var server: LocalServerSocket? = null

    @Volatile
    private var acceptJob: Job? = null

    private val sessionsGuard = Any()
    private val sessions = LinkedHashSet<NetworkInspectorSession>()

    @Volatile
    private var latestAppIcon: SnapOAppIcon? = null

    fun start(): Boolean {
        if (server != null) return true

        val boundServer = runCatching {
            LocalServerSocket(
                LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT).name
            )
        }.getOrNull() ?: return false

        latestAppIcon = appIconProvider.loadAppIcon()
        server = boundServer
        acceptJob = scope.launch(Dispatchers.IO) { acceptLoop(boundServer) }
        return true
    }

    override fun close() {
        acceptJob?.cancel()
        acceptJob = null
        snapshotSessions().forEach { it.close() }
        runCatching { server?.close() }
        server = null
    }

    fun broadcast(message: CdpMessage) {
        snapshotSessions().forEach { session ->
            if (!session.queueLive(message)) {
                session.close()
            }
        }
    }

    private suspend fun acceptLoop(server: LocalServerSocket) {
        while (currentCoroutineContext().isActive) {
            val socket = acceptSocketOrNull(server) ?: continue
            scope.launch(Dispatchers.IO) { handleAcceptedSocket(socket) }
        }
    }

    private fun acceptSocketOrNull(server: LocalServerSocket): LocalSocket? =
        try {
            server.accept()
        } catch (ce: kotlin.coroutines.cancellation.CancellationException) {
            throw ce
        } catch (_: Throwable) {
            null
        }

    private suspend fun handleAcceptedSocket(socket: LocalSocket) {
        val session = NetworkInspectorSession(
            socket = socket,
            appInfoProvider = ::buildAppInfoMessage,
            snapshotProvider = snapshotProvider,
            commandHandler = commandHandler,
            scope = scope,
        )
        registerSession(session)
        try {
            session.run()
        } finally {
            unregisterSession(session)
            session.close()
            runCatching { socket.close() }
        }
    }

    private fun buildAppInfoMessage(): CdpMessage {
        val params = SnapOAppInfoParams(
            protocolVersion = NetworkProtocolVersion,
            packageName = app.packageName,
            processName = appProcessName(),
            pid = Process.myPid(),
            serverStartWallMs = serverStartWallMs,
            serverStartMonoNs = serverStartMonoNs,
            mode = config.modeLabel,
            icon = latestAppIcon,
        )
        return CdpMessage(
            method = SnapOMethod.AppInfo,
            params = ProtocolJson.encodeToJsonElement(SnapOAppInfoParams.serializer(), params),
        )
    }

    private fun appProcessName(): String {
        return try {
            val am = app.getSystemService(Application.ACTIVITY_SERVICE) as ActivityManager
            val pid = Process.myPid()
            am.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName ?: app.packageName
        } catch (_: Throwable) {
            app.packageName
        }
    }

    private fun registerSession(session: NetworkInspectorSession) {
        synchronized(sessionsGuard) {
            sessions.add(session)
        }
    }

    private fun unregisterSession(session: NetworkInspectorSession) {
        synchronized(sessionsGuard) {
            sessions.remove(session)
        }
    }

    private fun snapshotSessions(): List<NetworkInspectorSession> =
        synchronized(sessionsGuard) { sessions.toList() }
}

private class NetworkInspectorSession(
    private val socket: LocalSocket,
    private val appInfoProvider: () -> CdpMessage,
    private val snapshotProvider: suspend () -> NetworkReplaySnapshot,
    private val commandHandler: suspend (CdpMessage) -> CdpMessage?,
    private val scope: CoroutineScope,
) {
    private val writer = BufferedWriter(OutputStreamWriter(socket.outputStream, StandardCharsets.UTF_8))
    private val reader = BufferedReader(InputStreamReader(socket.inputStream, StandardCharsets.UTF_8))
    private val outgoing = Channel<CdpMessage>(capacity = SessionQueueCapacity)
    private val operations = Channel<SessionOperation>(capacity = SessionQueueCapacity)

    @Volatile
    private var writerJob: Job? = null

    @Volatile
    private var processorJob: Job? = null

    @Volatile
    private var isClosed: Boolean = false

    suspend fun run() {
        if (!performClientHandshake()) {
            close()
            return
        }
        startWriter()
        startProcessor()
        sendWithBackpressure(appInfoProvider())

        while (!isClosed) {
            val line = runCatching { reader.readLine() }.getOrNull() ?: break
            decodeCommand(line)?.let { handleCommand(it) }
        }
    }

    fun queueLive(message: CdpMessage): Boolean {
        if (isClosed) return false
        return operations.trySendSuccessfully(SessionOperation.Live(message))
    }

    fun close() {
        if (isClosed) return
        isClosed = true
        writerJob?.cancel()
        writerJob = null
        processorJob?.cancel()
        processorJob = null
        outgoing.close()
        operations.close()
        runCatching { writer.close() }
        runCatching { reader.close() }
    }

    private fun startWriter() {
        if (writerJob != null || isClosed) return
        writerJob = scope.launch(Dispatchers.IO) {
            for (message in outgoing) {
                if (!writeLine(message)) {
                    close()
                    return@launch
                }
            }
        }
    }

    private fun startProcessor() {
        if (processorJob != null || isClosed) return
        processorJob = scope.launch {
            var streamStarted = false
            var replayWatermark: Long? = null
            for (operation in operations) {
                when (operation) {
                    SessionOperation.StartStream -> {
                        if (streamStarted) continue
                        replayWatermark = replaySnapshot()
                        if (isClosed) return@launch
                        streamStarted = true
                    }

                    SessionOperation.StopStream -> {
                        streamStarted = false
                        replayWatermark = null
                    }

                    is SessionOperation.Live -> {
                        val watermark = replayWatermark
                        if (streamStarted &&
                            (watermark == null || shouldDeliverAfterReplay(operation.message, watermark))
                        ) {
                            sendWithBackpressure(operation.message)
                        }
                    }
                }
            }
        }
    }

    private fun writeLine(message: CdpMessage): Boolean {
        return try {
            writer.write(ProtocolJson.encodeToString(CdpMessage.serializer(), message))
            writer.write("\n")
            writer.flush()
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun decodeCommand(line: String): CdpMessage? {
        if (line.isBlank()) return null
        return runCatching {
            ProtocolJson.decodeFromString(CdpMessage.serializer(), line)
        }.getOrNull()
    }

    private suspend fun handleCommand(message: CdpMessage) {
        when (message.method) {
            SnapOMethod.StartStream -> queueControl(SessionOperation.StartStream)
            SnapOMethod.StopStream -> queueControl(SessionOperation.StopStream)
            else -> commandHandler(message)?.let { sendWithBackpressure(it) }
        }
    }

    private suspend fun replaySnapshot(): Long {
        val snapshot = snapshotProvider()
        for (message in snapshot.messages) {
            if (!sendWithBackpressure(message)) return snapshot.watermark
        }
        val replayComplete = CdpMessage(
            method = SnapOMethod.ReplayComplete,
            params = ProtocolJson.encodeToJsonElement(
                SnapOReplayCompleteParams.serializer(),
                SnapOReplayCompleteParams(watermark = snapshot.watermark),
            ),
        )
        sendWithBackpressure(replayComplete)
        return snapshot.watermark
    }

    private suspend fun queueControl(operation: SessionOperation) {
        if (isClosed) return
        runCatching { operations.send(operation) }
    }

    private suspend fun sendWithBackpressure(message: CdpMessage): Boolean {
        if (isClosed) return false
        return runCatching { outgoing.send(message) }
            .fold(
                onSuccess = { true },
                onFailure = {
                    close()
                    false
                },
            )
    }

    private fun performClientHandshake(): Boolean {
        return try {
            readClientHello() == ClientHelloToken
        } catch (_: SocketTimeoutException) {
            false
        } catch (_: IOException) {
            false
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

    private sealed interface SessionOperation {
        object StartStream : SessionOperation
        object StopStream : SessionOperation
        data class Live(val message: CdpMessage) : SessionOperation
    }
}

private const val SessionQueueCapacity = 512
private const val ClientHelloToken = "HelloSnapO"
private const val ClientHelloTimeoutMs = 1_000
private const val ClientHelloMaxBytes = 4 * 1024

internal fun <T> SendChannel<T>.trySendSuccessfully(element: T): Boolean =
    trySend(element).isSuccess

internal fun shouldDeliverAfterReplay(message: CdpMessage, watermark: Long): Boolean =
    message.snapoSequence?.let { sequence -> sequence > watermark } ?: true

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
import kotlinx.coroutines.launch
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.Closeable
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets
import kotlin.coroutines.cancellation.CancellationException

internal class NetworkInspectorTransport(
    private val app: Application,
    private val config: NetworkInspectorConfig,
    private val snapshotProvider: suspend () -> List<CdpMessage>,
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
            if (!session.send(message)) {
                session.close()
            }
        }
    }

    private suspend fun acceptLoop(server: LocalServerSocket) {
        while (acceptJob?.isActive != false) {
            val socket = acceptSocketOrNull(server) ?: continue
            scope.launch(Dispatchers.IO) { handleAcceptedSocket(socket) }
        }
    }

    private fun acceptSocketOrNull(server: LocalServerSocket): LocalSocket? =
        try {
            server.accept()
        } catch (ce: CancellationException) {
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
    socket: LocalSocket,
    private val appInfoProvider: () -> CdpMessage,
    private val snapshotProvider: suspend () -> List<CdpMessage>,
    private val commandHandler: suspend (CdpMessage) -> CdpMessage?,
    private val scope: CoroutineScope,
) {
    private val writer = BufferedWriter(OutputStreamWriter(socket.outputStream, StandardCharsets.UTF_8))
    private val reader = BufferedReader(InputStreamReader(socket.inputStream, StandardCharsets.UTF_8))
    private val outgoing = Channel<CdpMessage>(capacity = OutgoingQueueCapacity)

    @Volatile
    private var writerJob: Job? = null

    @Volatile
    private var isClosed: Boolean = false

    suspend fun run() {
        startWriter()
        send(appInfoProvider())
        snapshotProvider().forEach(::send)
        send(
            CdpMessage(
                method = SnapOMethod.ReplayComplete,
            )
        )

        while (!isClosed) {
            val line = runCatching { reader.readLine() }.getOrNull() ?: break
            decodeCommand(line)?.let { message ->
                commandHandler(message)?.let(::send)
            }
        }
    }

    fun send(message: CdpMessage): Boolean {
        if (isClosed) return false
        val result = outgoing.trySend(message)
        if (result.isSuccess) return true
        if (result.isClosed) return false
        scope.launch {
            runCatching { outgoing.send(message) }
        }
        return true
    }

    fun close() {
        if (isClosed) return
        isClosed = true
        writerJob?.cancel()
        writerJob = null
        outgoing.close()
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
}

private const val OutgoingQueueCapacity = 512

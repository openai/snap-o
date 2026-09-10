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
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap

internal data class NetworkReplaySnapshot(
    val messages: List<CdpMessage>,
    val watermark: Long,
)

internal class NetworkInspectorTransport(
    private val app: Application,
    private val config: NetworkInspectorConfig,
    private val snapshotProvider: suspend () -> NetworkReplaySnapshot,
    private val commandHandler: suspend (CdpMessage) -> CdpMessage?,
    private val interception: NetworkInterception,
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

    private val connections = ConcurrentHashMap.newKeySet<LocalSocket>()
    private val connectionSlots = Semaphore(128)

    private val appIcon: SnapOAppIcon? by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        appIconProvider.loadAppIcon()
    }

    private val http by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        NetworkInspectorHttp(
            buildAppInfo(),
            runCatching { app.applicationInfo.loadLabel(app.packageManager).toString() }.getOrDefault(app.packageName),
            snapshotProvider,
            commandHandler,
            interception,
        )
    }

    fun start(): Boolean {
        if (server != null) return true

        val boundServer = runCatching {
            LocalServerSocket(
                LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT).name
            )
        }.getOrNull() ?: return false

        server = boundServer
        acceptJob = scope.launch(Dispatchers.IO) { acceptLoop(boundServer) }
        return true
    }

    override fun close() {
        acceptJob?.cancel()
        acceptJob = null
        http.close()
        connections.forEach { runCatching { it.close() } }
        runCatching { server?.close() }
        server = null
    }

    fun broadcast(message: CdpMessage) {
        http.broadcast(message)
    }

    private suspend fun acceptLoop(server: LocalServerSocket) {
        while (currentCoroutineContext().isActive) {
            val socket = acceptSocketOrNull(server) ?: continue
            if (connectionSlots.tryAcquire()) {
                connections.add(socket)
                scope.launch(Dispatchers.IO) { handleAcceptedSocket(socket) }
            } else {
                runCatching { socket.close() }
            }
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
        try {
            socket.soTimeout = 5000
            http.serveConnection(
                socket.inputStream,
                socket.outputStream,
                onRequestRead = { socket.soTimeout = 0 },
                closeConnection = { runCatching { socket.close() } },
            )
        } finally {
            connections.remove(socket)
            connectionSlots.release()
            runCatching { socket.close() }
        }
    }

    private fun buildAppInfo(): SnapOAppInfoParams = SnapOAppInfoParams(
        protocolVersion = NetworkProtocolVersion,
        packageName = app.packageName,
        processName = appProcessName(),
        pid = Process.myPid(),
        serverStartWallMs = serverStartWallMs,
        serverStartMonoNs = serverStartMonoNs,
        mode = config.modeLabel,
        icon = appIcon,
    )

    private fun appProcessName(): String {
        return try {
            val am = app.getSystemService(Application.ACTIVITY_SERVICE) as ActivityManager
            val pid = Process.myPid()
            am.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName ?: app.packageName
        } catch (_: Throwable) {
            app.packageName
        }
    }
}

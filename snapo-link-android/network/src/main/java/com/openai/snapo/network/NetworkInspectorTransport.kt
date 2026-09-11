package com.openai.snapo.network

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Process
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
    private val snapshotProvider: suspend () -> NetworkReplaySnapshot,
    private val commandHandler: suspend (CdpMessage) -> CdpMessage?,
    private val interception: NetworkInterception,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) : Closeable {
    val socketName: String = "snapo_network_${Process.myPid()}"

    @Volatile
    private var server: LocalServerSocket? = null

    @Volatile
    private var acceptJob: Job? = null

    private val connections = ConcurrentHashMap.newKeySet<LocalSocket>()
    private val connectionSlots = Semaphore(128)

    private val http by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        NetworkInspectorHttp(
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

}

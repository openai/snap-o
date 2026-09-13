package com.openai.snapo.tool

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Process
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Semaphore

/** A connection belongs to the server until its handler returns or the server closes. */
interface ToolConnection : Closeable {
    val input: InputStream
    val output: OutputStream
    fun setReadTimeout(millis: Int)
}

/** One abstract Unix socket per tool plugin and process. Binding failures are reported to the caller. */
internal class ToolSocketServer constructor(
    private val maxConnections: Int,
    private val bind: () -> ToolSocketListener,
    private val handleConnection: suspend (ToolConnection) -> Unit,
) : Closeable {
    constructor(
        toolId: String,
        maxConnections: Int = 32,
        handleConnection: suspend (ToolConnection) -> Unit,
    ) : this(
        maxConnections,
        { LocalToolListener(socketName(toolId)) },
        handleConnection,
    )

    private val lock = Any()
    private var session: Session? = null

    init {
        require(maxConnections > 0)
    }

    val isRunning: Boolean
        get() = synchronized(lock) { session != null }

    fun start() {
        synchronized(lock) {
            if (session != null) return
            val started = Session(bind(), maxConnections)
            session = started
            started.scope.launch { acceptConnections(started) }
        }
    }

    internal fun startIfAllowed(allowed: Boolean, onFailure: (IOException) -> Unit): Boolean {
        if (!allowed) return false
        return try {
            start()
            true
        } catch (failure: IOException) {
            // start() publishes a session only after binding succeeds, so a failed bind owns no session.
            onFailure(failure)
            false
        }
    }

    override fun close() {
        synchronized(lock) {
            val closing = session ?: return
            session = null
            closing.scope.cancel()
            runCatching { closing.listener.close() }
            closing.connections.forEach { runCatching { it.close() } }
            closing.connections.clear()
        }
    }

    private fun acceptConnections(started: Session) {
        try {
            while (synchronized(lock) { session === started }) {
                val connection = started.listener.accept()
                synchronized(lock) {
                    if (session !== started || !started.permits.tryAcquire()) {
                        runCatching { connection.close() }
                    } else {
                        serve(started, connection)
                    }
                }
            }
        } catch (_: IOException) {
            // Closing the listening socket wakes a blocked accept.
        } finally {
            synchronized(lock) {
                if (session === started) close()
            }
        }
    }

    private fun serve(started: Session, connection: ToolConnection) {
        started.connections.add(connection)
        val job = started.scope.launch {
            try {
                connection.setReadTimeout(5_000)
                handleConnection(connection)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // A failed connection must not stop other tool plugins or crash the app.
            }
        }
        // Completion also runs when shutdown cancels a handler before it starts.
        job.invokeOnCompletion {
            synchronized(lock) { started.connections.remove(connection) }
            runCatching { connection.close() }
            started.permits.release()
        }
    }

    private class Session(val listener: ToolSocketListener, maxConnections: Int) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val permits = Semaphore(maxConnections)
        val connections = LinkedHashSet<ToolConnection>()
    }

    companion object {
        fun socketName(toolId: String, processId: Int = Process.myPid()): String {
            require(Regex("[a-z][a-z0-9.-]{0,99}").matches(toolId)) { "Invalid tool id" }
            require(processId > 0) { "Invalid process id" }
            return "snapo_${toolId}_$processId"
        }
    }
}

internal interface ToolSocketListener : Closeable {
    fun accept(): ToolConnection
}

private class LocalToolListener(name: String) : ToolSocketListener {
    private val server = LocalServerSocket(name)
    override fun accept(): ToolConnection = LocalToolConnection(server.accept())
    override fun close() = server.close()
}

private class LocalToolConnection(private val socket: LocalSocket) : ToolConnection {
    override val input: InputStream get() = socket.inputStream
    override val output: OutputStream get() = socket.outputStream
    override fun setReadTimeout(millis: Int) { socket.soTimeout = millis }
    override fun close() = socket.close()
}

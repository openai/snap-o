package com.openai.snapo.tool

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.Closeable
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicReference
import java.util.logging.Level
import java.util.logging.Logger

/** An HTTP server on the tool plugin's process-local abstract socket. No Android startup is performed. */
class ToolServer(
    private val toolId: String,
    maxConnections: Int = 32,
    configure: ToolRoutes.() -> Unit,
) : Closeable {
    private val routes = ToolRoutes().apply(configure)
    private val socket = ToolSocketServer(toolId, maxConnections, ::serve)
    val isRunning: Boolean get() = socket.isRunning

    fun start() = socket.start()

    /** Returns false when startup is disallowed or the socket cannot be opened. */
    fun startIfAllowed(
        context: Context,
        releaseMetadataKey: String = "snapo.$toolId.allow_release",
        allowRelease: Boolean = false,
    ): Boolean = socket.startIfAllowed(
        ToolStartupPolicy.isAllowed(context.applicationContext, releaseMetadataKey, allowRelease),
    ) { failure ->
        Log.e("SnapOTool", "Could not start tool plugin $toolId.", failure)
    }

    override fun close() = socket.close()

    /** Serves and closes one supplied connection. Useful for tests and alternate socket transports. */
    @Suppress("TooGenericExceptionCaught") // Domain handlers may throw arbitrary exceptions; isolate each response.
    suspend fun serve(connection: ToolConnection) = coroutineScope {
        val scope = this
        val call = AtomicReference<ToolCall>()
        val deadline = launch(Dispatchers.Default) {
            delay(30_000)
            runCatching { connection.close() }
            scope.cancel()
        }
        val watchdog = launch(Dispatchers.Default) {
            while (isActive) {
                delay(1000)
                val started = call.get()?.writeStartedNs ?: 0L
                if (started != 0L && System.nanoTime() - started > 5_000_000_000L) {
                    runCatching { connection.close() }
                    scope.cancel()
                }
            }
        }
        try {
            connection.setReadTimeout(5_000)
            val request = readRequest(connection)
            connection.setReadTimeout(0)
            val headers = ToolBrowserAccess.responseHeaders(
                request.headers["origin"],
                routes.entries.map { it.method }.distinct().joinToString(", "),
                routes.exposedHeaders,
                routes.vary,
            ) + ("Cache-Control" to routes.cacheControl)
            val current = ToolCall(request, connection, headers) { deadline.cancel() }
            call.set(current)
            routes.validate(request)
            if (request.method == "OPTIONS") {
                current.respond(ToolHttpResponse(routes.preflightStatusCode, byteArrayOf()))
            } else {
                dispatch(current)
                if (!current.responseStarted) current.respondNoContent()
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            if (call.get()?.responseStarted != true) {
                runCatching {
                    val response = routes.errorResponse(error)
                    if (response.statusCode >= 500) {
                        Logger.getLogger("SnapOTool").log(Level.SEVERE, "Tool $toolId request failed", error)
                    }
                    call.get()?.respond(response) ?: response.write(connection.output)
                }
            }
        } finally {
            runCatching { connection.close() }
            deadline.cancel()
            watchdog.cancel()
        }
    }

    private fun readRequest(connection: ToolConnection): ToolHttpRequest = try {
        ToolHttpRequest.read(connection.input, routes.requestPolicy)
    } catch (error: ToolHttpException) {
        throw error
    } catch (error: SocketTimeoutException) {
        throw ToolHttpException(408, "Request timed out", error)
    } catch (error: IllegalArgumentException) {
        throw ToolHttpException(400, "Invalid HTTP request", error)
    } catch (error: IOException) {
        throw ToolHttpException(400, "Incomplete HTTP request", error)
    }

    private suspend fun dispatch(call: ToolCall) {
        val path = call.request.path
        val matches = routes.entries.mapNotNull { route -> route.match(path)?.let { route to it } }
        val match = matches.firstOrNull { it.first.method == call.request.method }
        if (match != null) {
            call.pathParameters = match.second
            match.first.handler(call)
        } else if (matches.isNotEmpty()) {
            val methods = matches.map { it.first.method }.distinct().joinToString(", ")
            throw ToolHttpException(405, "Use $methods", allowedMethods = methods)
        } else {
            routes.fallback(call)
        }
    }
}

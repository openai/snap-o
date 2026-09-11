package com.openai.snapo.inspector

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.Closeable
import java.util.concurrent.atomic.AtomicReference

/** An HTTP server on the inspector's process-local abstract socket. No Android startup is performed. */
class InspectorServer(
    inspectorId: String,
    maxConnections: Int = 32,
    configure: InspectorRoutes.() -> Unit,
) : Closeable {
    private val routes = InspectorRoutes().apply(configure)
    private val socket = InspectorSocketServer(inspectorId, maxConnections, ::serve)
    val isRunning: Boolean get() = socket.isRunning

    fun start() = socket.start()
    override fun close() = socket.close()

    /** Serves and closes one supplied connection. Useful for tests and alternate socket transports. */
    @Suppress("TooGenericExceptionCaught") // Domain handlers may throw arbitrary exceptions; isolate each response.
    suspend fun serve(connection: InspectorConnection) = coroutineScope {
        val scope = this
        val call = AtomicReference<InspectorCall>()
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
            val request = InspectorHttpRequest.read(connection.input, routes.requestPolicy)
            connection.setReadTimeout(0)
            val headers = InspectorBrowserAccess.responseHeaders(
                request.headers["origin"],
                routes.entries.map { it.method }.distinct().joinToString(", "),
                routes.exposedHeaders,
                routes.vary,
            ) + ("Cache-Control" to routes.cacheControl)
            val current = InspectorCall(request, connection, headers) { deadline.cancel() }
            call.set(current)
            routes.validate(request)
            if (request.method == "OPTIONS") {
                current.respond(InspectorHttpResponse(routes.preflightStatusCode, byteArrayOf()))
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
                    call.get()?.respond(response) ?: response.write(connection.output)
                }
            }
        } finally {
            runCatching { connection.close() }
            deadline.cancel()
            watchdog.cancel()
        }
    }

    private suspend fun dispatch(call: InspectorCall) {
        val path = call.request.path
        val matches = routes.entries.mapNotNull { route -> route.match(path)?.let { route to it } }
        val match = matches.firstOrNull { it.first.method == call.request.method }
        if (match != null) {
            call.pathParameters = match.second
            match.first.handler(call)
        } else if (matches.isNotEmpty()) {
            val methods = matches.map { it.first.method }.distinct().joinToString(", ")
            throw InspectorHttpException(405, "Use $methods", allowedMethods = methods)
        } else {
            routes.fallback(call)
        }
    }
}

package com.openai.snapo.network

import com.openai.snapo.tool.ToolCall
import com.openai.snapo.tool.ToolHttpException
import com.openai.snapo.tool.ToolHttpRequest
import com.openai.snapo.tool.ToolHttpRequestPolicy
import com.openai.snapo.tool.ToolServer
import kotlinx.coroutines.sync.Semaphore
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.net.URI
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** HTTP reads and SSE subscriptions on the tool's existing abstract socket. */
internal class NetworkToolHttp(
    private val snapshotProvider: suspend () -> NetworkReplaySnapshot = { NetworkReplaySnapshot(emptyList(), 0) },
    private val commandHandler: suspend (CdpMessage) -> CdpMessage? = { null },
    private val interception: NetworkInterception = NetworkInterception(),
) {
    private val streamSlots = Semaphore(16)
    private val subscribers = ConcurrentHashMap.newKeySet<NetworkEventStream>()
    private val runners = ConcurrentHashMap<String, NetworkEventStream>()

    fun broadcast(message: CdpMessage) {
        if (subscribers.isEmpty()) return
        val event = runCatching { networkSseEvent(message) }.getOrElse {
            subscribers.forEach { it.close() }
            return
        }
        subscribers.forEach { it.offer(event) }
    }

    fun close() {
        server.close()
        subscribers.forEach { it.close() }
        runners.values.forEach { it.close() }
    }

    val server = ToolServer(SnapOTool.ID, maxConnections = 128) {
        requestPolicy = RequestPolicy
        exposedHeaders = "SnapO-Sequence, Location"
        vary = "Accept, Origin"
        get("/network") {
            if (eventStreamRequested(request)) stream(null) else history()
        }
        post("/interception") { stream(request.json()) }
        put("/interception/{runnerId}/routes") {
            configureRunner(runner(pathParameters.getValue("runnerId")), request.json())
            respondJson("{}")
        }
        post("/interception/{runnerId}/exchanges/{exchangeId}") {
            val stream = runner(pathParameters.getValue("runnerId"))
            val params =
                JsonObject(request.json() + ("exchangeId" to JsonPrimitive(pathParameters.getValue("exchangeId"))))
            withRunner(stream, 409) { interception.resolve(stream, params) }
            respondJson("{}")
        }
        get("/network/requests/{requestId}/request-body") { body(CdpNetworkMethod.GetRequestPostData) }
        get("/network/requests/{requestId}/response-body") { body(CdpNetworkMethod.GetResponseBody) }
        notFound {
            // Keep the existing distinction between expired interception owners and unknown paths.
            if (URI.create(request.requestTarget).path.startsWith("/interception/")) {
                runner(request.path.split('/').getOrElse(2) { "" })
                notFound()
            } else {
                requireMethod(request, "GET")
                notFound()
            }
        }
    }

    private fun eventStreamRequested(request: ToolHttpRequest): Boolean {
        val accept = request.headers["accept"] ?: return false
        val formats = listOf("application/x-ndjson", "text/event-stream")
        val preferences = formats.map { format ->
            accept.split(',').mapNotNull { entry ->
                val parts = entry.trim().lowercase().split(';').map { it.trim() }
                val specificity = when (parts.first()) {
                    format -> 2
                    format.substringBefore('/') + "/*" -> 1
                    "*/*" -> 0
                    else -> return@mapNotNull null
                }
                val weight = parts.drop(1).firstOrNull { it.startsWith("q=") }?.removePrefix("q=")
                val quality = if (weight == null) {
                    1.0
                } else {
                    requireNotNull(weight.toDoubleOrNull()) {
                        "Invalid Accept quality"
                    }
                }
                require(quality in 0.0..1.0) { "Invalid Accept quality" }
                specificity to quality
            }.maxByOrNull { it.first }?.second ?: 0.0
        }
        if (preferences.all { it == 0.0 }) {
            throw ToolHttpException(406, "Use application/x-ndjson or text/event-stream")
        }
        return preferences[1] > preferences[0]
    }

    private suspend fun ToolCall.body(method: String) {
        val requestId = pathParameters.getValue("requestId")
        require(requestId.isNotEmpty() && requestId.length <= 512) { "Invalid request id" }
        val reply = commandHandler(
            CdpMessage(
                id = 1,
                method = method,
                params = JsonObject(mapOf("requestId" to JsonPrimitive(requestId))),
            )
        )
        val result = reply?.result ?: throw ToolHttpException(404, reply?.error?.message ?: "Body is unavailable")
        respondJson(result.toString())
    }

    private suspend fun ToolCall.stream(routes: JsonObject?) {
        if (!streamSlots.tryAcquire()) throw ToolHttpException(503, "Too many event streams")
        val stream = NetworkEventStream()
        val runnerId = if (routes == null) null else UUID.randomUUID().toString()
        try {
            if (runnerId == null) {
                subscribers.add(stream)
            } else {
                runners[runnerId] = stream
                configureRunner(stream, requireNotNull(routes))
            }
            respondSse(
                statusCode = if (runnerId == null) 200 else 201,
                headers = runnerId?.let { mapOf("Location" to "/interception/$it") }.orEmpty(),
            ) { stream.serve(this) }
        } finally {
            subscribers.remove(stream)
            if (runnerId != null) runners.remove(runnerId, stream)
            interception.disconnect(stream)
            stream.close()
            streamSlots.release()
        }
    }

    private fun runner(id: String): NetworkEventStream = runners[id]?.takeUnless { it.isClosed }
        ?: throw ToolHttpException(410, "Interception runner has ended")

    private fun configureRunner(stream: NetworkEventStream, params: JsonObject) {
        withRunner(stream, 400) {
            interception.configure(stream, { message ->
                runCatching { stream.offer(networkSseEvent(message)) }.getOrDefault(false)
            }, params)
        }
    }

    private fun withRunner(stream: NetworkEventStream, errorStatus: Int, action: () -> Unit) {
        try {
            action()
        } catch (error: IllegalArgumentException) {
            throw ToolHttpException(errorStatus, error.message ?: "Invalid interception request", error)
        }
        // Closing the stream may race a route update on another HTTP connection.
        if (stream.isClosed) {
            interception.disconnect(stream)
            throw ToolHttpException(410, "Interception runner has ended")
        }
    }

    private suspend fun ToolCall.history() {
        val snapshot = snapshotProvider()
        respondStream("application/x-ndjson", headers = mapOf("SnapO-Sequence" to snapshot.watermark.toString())) {
            for (message in snapshot.messages) {
                val bytes = ProtocolJson.encodeToString(CdpMessage.serializer(), message).toByteArray(Charsets.UTF_8)
                require(bytes.size <= MaxNetworkRecordBytes) { "History record is too large" }
                write(bytes + '\n'.code.toByte())
            }
        }
    }

    private fun notFound(): Nothing = throw ToolHttpException(404, "Unknown endpoint")

    private fun requireMethod(request: ToolHttpRequest, method: String) {
        if (request.method != method) throw ToolHttpException(405, "Use $method")
    }

    private fun ToolHttpRequest.json(): JsonObject =
        ProtocolJson.parseToJsonElement(bodyText()).jsonObject
}

private val RequestPolicy = ToolHttpRequestPolicy(
    maxBodyBytes = 2 * 1024 * 1024,
    bodyMethods = setOf("POST", "PUT"),
)
internal const val MaxNetworkRecordBytes = 16 * 1024 * 1024

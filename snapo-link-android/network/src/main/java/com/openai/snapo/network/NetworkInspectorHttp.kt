package com.openai.snapo.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URLDecoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.io.encoding.Base64

/** HTTP reads and SSE subscriptions on the inspector's existing abstract socket. */
internal class NetworkInspectorHttp(
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
        subscribers.forEach { it.close() }
        runners.values.forEach { it.close() }
    }

    suspend fun serveConnection(
        input: InputStream,
        output: OutputStream,
        onRequestRead: () -> Unit = {},
        closeConnection: () -> Unit = {},
    ) {
        try {
            val request = InspectorHttpRequest.read(input)
            onRequestRead()
            respond(request, output, input, closeConnection)
        } catch (_: SocketTimeoutException) {
            runCatching { json(output, JsonPrimitive("Request timed out"), "408 Request Timeout") }
        } catch (_: IOException) {
            // A closed client cannot receive a response, including during an SSE stream.
        } catch (error: IllegalArgumentException) {
            runCatching { json(output, JsonPrimitive(error.message ?: "Invalid request"), "400 Bad Request") }
        }
    }

    suspend fun respond(
        request: InspectorHttpRequest,
        output: OutputStream,
        input: InputStream = ByteArrayInputStream(byteArrayOf()),
        closeConnection: () -> Unit = {},
    ) = coroutineScope {
        val deadline = launch(Dispatchers.Default) {
            delay(30_000)
            closeConnection()
        }
        val headers = request.headers["origin"]?.let {
            "Access-Control-Allow-Origin: $it\r\n" +
                "Access-Control-Expose-Headers: SnapO-Sequence, Location\r\n" +
                "Access-Control-Allow-Methods: GET, POST, PUT\r\n" +
                "Access-Control-Allow-Headers: Content-Type\r\n"
        } ?: ""
        try {
            val uri = URI.create(request.path)
            when {
                request.method == "OPTIONS" -> respond(output, "204 No Content", "text/plain", byteArrayOf(), headers)
                uri.path == "/network" -> {
                    requireMethod(request, "GET")
                    if (eventStreamRequested(request)) {
                        deadline.cancel()
                        stream(null, input, output, closeConnection, headers)
                    } else {
                        history(output, headers)
                    }
                }
                uri.path == "/interception" -> {
                    requireMethod(request, "POST")
                    deadline.cancel()
                    stream(request.json(), input, output, closeConnection, headers)
                }
                uri.path.startsWith("/interception/") -> updateRunner(request, uri, output, headers)
                else -> read(request, uri, output, headers)
            }
        } catch (error: HttpFailure) {
            json(output, JsonObject(mapOf("error" to JsonPrimitive(error.message))), error.status, headers)
        } catch (error: IllegalArgumentException) {
            json(
                output,
                JsonObject(mapOf("error" to JsonPrimitive(error.message ?: "Invalid request"))),
                "400 Bad Request",
                headers
            )
        } finally {
            deadline.cancel()
        }
    }

    private fun eventStreamRequested(request: InspectorHttpRequest): Boolean {
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
            throw HttpFailure("406 Not Acceptable", "Use application/x-ndjson or text/event-stream")
        }
        return preferences[1] > preferences[0]
    }

    private suspend fun read(request: InspectorHttpRequest, uri: URI, output: OutputStream, headers: String) {
        requireMethod(request, "GET")
        body(uri, output, headers)
    }

    private suspend fun body(uri: URI, output: OutputStream, headers: String) {
        val parts = uri.rawPath.split('/')
        if (parts.size != 5 || parts[1] != "network" || parts[2] != "requests") {
            notFound()
        }
        val method = when (parts[4]) {
            "request-body" -> CdpNetworkMethod.GetRequestPostData
            "response-body" -> CdpNetworkMethod.GetResponseBody
            else -> notFound()
        }
        val requestId = URLDecoder.decode(parts[3].replace("+", "%2B"), "UTF-8")
        require(requestId.isNotEmpty() && requestId.length <= 512) { "Invalid request id" }
        val reply = commandHandler(
            CdpMessage(
                id = 1,
                method = method,
                params = JsonObject(mapOf("requestId" to JsonPrimitive(requestId))),
            )
        )
        val result = reply?.result ?: throw HttpFailure("404 Not Found", reply?.error?.message ?: "Body is unavailable")
        json(output, result, headers = headers)
    }

    private suspend fun stream(
        routes: JsonObject?,
        input: InputStream,
        output: OutputStream,
        closeConnection: () -> Unit,
        headers: String,
    ) {
        if (!streamSlots.tryAcquire()) throw HttpFailure("503 Service Unavailable", "Too many event streams")
        val stream = NetworkEventStream(closeConnection)
        val runnerId = if (routes == null) null else UUID.randomUUID().toString()
        try {
            if (runnerId == null) {
                subscribers.add(stream)
            } else {
                runners[runnerId] = stream
                configureRunner(stream, requireNotNull(routes))
            }
            stream.serve(input, output, runnerId?.let { "/interception/$it" }, headers)
        } finally {
            subscribers.remove(stream)
            if (runnerId != null) runners.remove(runnerId, stream)
            interception.disconnect(stream)
            stream.close()
            streamSlots.release()
        }
    }

    private fun updateRunner(request: InspectorHttpRequest, uri: URI, output: OutputStream, headers: String) {
        val parts = uri.rawPath.split('/')
        val runnerId = parts.getOrNull(2) ?: notFound()
        val stream = runners[runnerId]?.takeUnless { it.isClosed }
            ?: throw HttpFailure("410 Gone", "Interception runner has ended")
        when {
            parts.size == 4 && parts[3] == "routes" -> {
                requireMethod(request, "PUT")
                configureRunner(stream, request.json())
            }
            parts.size == 5 && parts[3] == "exchanges" -> {
                requireMethod(request, "POST")
                val params = JsonObject(request.json() + ("exchangeId" to JsonPrimitive(parts[4])))
                withRunner(stream, "409 Conflict") { interception.resolve(stream, params) }
            }
            else -> notFound()
        }
        json(output, JsonObject(emptyMap()), headers = headers)
    }

    private fun configureRunner(stream: NetworkEventStream, params: JsonObject) {
        withRunner(stream, "400 Bad Request") {
            interception.configure(stream, { message ->
                runCatching { stream.offer(networkSseEvent(message)) }.getOrDefault(false)
            }, params)
        }
    }

    private fun withRunner(stream: NetworkEventStream, errorStatus: String, action: () -> Unit) {
        try {
            action()
        } catch (error: IllegalArgumentException) {
            throw HttpFailure(errorStatus, error.message ?: "Invalid interception request", error)
        }
        // Closing the stream may race a route update on another HTTP connection.
        if (stream.isClosed) {
            interception.disconnect(stream)
            throw HttpFailure("410 Gone", "Interception runner has ended")
        }
    }

    private suspend fun history(output: OutputStream, headers: String) {
        val snapshot = snapshotProvider()
        output.write(
            (
                "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n" +
                    "SnapO-Sequence: ${snapshot.watermark}\r\n" +
                    "Connection: close\r\nCache-Control: no-store\r\n" +
                    "Vary: Accept, Origin\r\n${headers}\r\n"
                ).toByteArray(Charsets.US_ASCII)
        )
        for (message in snapshot.messages) {
            val bytes = ProtocolJson.encodeToString(CdpMessage.serializer(), message).toByteArray(Charsets.UTF_8)
            require(bytes.size <= MaxNetworkRecordBytes) { "History record is too large" }
            output.write("${(bytes.size + 1).toString(16)}\r\n".toByteArray(Charsets.US_ASCII))
            output.write(bytes)
            output.write("\n\r\n".toByteArray(Charsets.US_ASCII))
        }
        output.write("0\r\n\r\n".toByteArray(Charsets.US_ASCII))
        output.flush()
    }

    private fun notFound(): Nothing = throw HttpFailure("404 Not Found", "Unknown endpoint")

    private fun requireMethod(request: InspectorHttpRequest, method: String) {
        if (request.method != method) throw HttpFailure("405 Method Not Allowed", "Use $method")
    }

    private fun InspectorHttpRequest.json(): JsonObject =
        ProtocolJson.parseToJsonElement(body.decodeToString(throwOnInvalidSequence = true)).jsonObject

    private fun json(output: OutputStream, value: JsonElement, status: String = "200 OK", headers: String = "") {
        respond(
            output,
            status,
            "application/json; charset=utf-8",
            value.toString().toByteArray(Charsets.UTF_8),
            headers
        )
    }

    private fun respond(
        output: OutputStream,
        status: String,
        contentType: String,
        body: ByteArray,
        headers: String = "",
    ) {
        output.write(
            (
                "HTTP/1.1 $status\r\nContent-Type: $contentType\r\nContent-Length: ${body.size}\r\n" +
                    "Connection: close\r\nCache-Control: no-store\r\n" +
                    "Vary: Accept, Origin\r\n${headers}\r\n"
                ).toByteArray(Charsets.US_ASCII)
        )
        output.write(body)
        output.flush()
    }
}

private class HttpFailure(
    val status: String,
    override val message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

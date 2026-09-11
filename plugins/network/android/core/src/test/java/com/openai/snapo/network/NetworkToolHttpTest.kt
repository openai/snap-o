package com.openai.snapo.network

import com.openai.snapo.plugin.PluginConnection
import com.openai.snapo.plugin.PluginHttpRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedReader
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NetworkToolHttpTest {
    @Test
    fun `readiness does not require HTTP metadata endpoints`() {
        val (status, body) = request("/", method = "OPTIONS")
        assertEquals("HTTP/1.1 204 No Content", status)
        assertEquals("", body)
        assertEquals("HTTP/1.1 404 Not Found", request("/.snap-o/info").first)
        assertEquals("HTTP/1.1 404 Not Found", request("/.snap-o/appicon").first)
        assertEquals("HTTP/1.1 404 Not Found", request("/unknown").first)
        assertEquals("HTTP/1.1 405 Method Not Allowed", request("/.snap-o/info", method = "POST").first)
    }

    @Test
    fun `HTTP history streams events and a snapshot cursor`() {
        val event = CdpMessage(method = "Network.loadingFinished", snapoSequence = 7)
        Fixture(
            NetworkToolHttp(snapshotProvider = { NetworkReplaySnapshot(listOf(event), 9) })
        ).use { server ->
            val response = server.request("/network")
            assertEquals(200, response.statusCode())
            assertEquals("application/x-ndjson", response.headers().firstValue("Content-Type").get())
            assertEquals("9", response.headers().firstValue("SnapO-Sequence").get())
            assertEquals("http://localhost", response.headers().firstValue("Access-Control-Allow-Origin").get())
            assertEquals(ProtocolJson.encodeToString(CdpMessage.serializer(), event) + "\n", response.body())
        }
    }

    @Test
    fun `network snapshot is the default and unsupported representations fail`() {
        assertEquals("HTTP/1.1 200 OK", request("/network").first)
        assertEquals("HTTP/1.1 200 OK", request("/network", accept = "application/x-ndjson").first)
        assertEquals("HTTP/1.1 200 OK", request("/network", accept = "text/event-stream;q=0, */*").first)
        assertEquals("HTTP/1.1 406 Not Acceptable", request("/network", accept = "application/json").first)
        assertEquals("HTTP/1.1 406 Not Acceptable", request("/network", accept = "*/*;q=0").first)
        assertEquals("HTTP/1.1 404 Not Found", request("/history").first)
        assertEquals("HTTP/1.1 404 Not Found", request("/network/events").first)
    }

    @Test
    fun `body reads return HTTP JSON without command envelopes`() {
        val http = NetworkToolHttp(commandHandler = { message ->
            assertEquals(CdpNetworkMethod.GetResponseBody, message.method)
            assertEquals("request+1", message.params?.jsonObject?.get("requestId")?.jsonPrimitive?.content)
            CdpMessage(id = 1, result = JsonObject(mapOf("body" to JsonPrimitive("hello"))))
        })
        Fixture(http).use { server ->
            val response = server.request("/network/requests/request%2B1/response-body")
            assertEquals(200, response.statusCode())
            assertEquals("{\"body\":\"hello\"}", response.body())
        }
    }

    @Test
    fun `standard HTTP client receives live SSE without an upgrade`() {
        val http = NetworkToolHttp()
        Fixture(http).use { server ->
            server.stream("/network").use { reader ->
                http.broadcast(CdpMessage(method = "Network.loadingFinished", snapoSequence = 42))
                assertEquals("id: 42", reader.readLine())
                val data = reader.readLine().removePrefix("data: ")
                assertEquals(
                    "Network.loadingFinished",
                    ProtocolJson.parseToJsonElement(data).jsonObject["method"]?.jsonPrimitive?.content
                )
                assertEquals("", reader.readLine())
            }
        }
    }

    @Test
    fun `registration returns its location and Python decisions use HTTP with phase checks`() {
        val engine = NetworkInterception()
        Fixture(NetworkToolHttp(interception = engine)).use { server ->
            server.stream("/interception", routes(), "POST").use { reader ->
                val runner = server.runnerId(reader)
                val exchange = requireNotNull(engine.open("GET", "/api/profile"))
                exchange.use {
                    exchange.request(InterceptionRequest("GET", "https://example.test/api/profile", emptyList(), ""))
                    assertEquals("SnapO.intercept.request", data(reader)["method"]?.jsonPrimitive?.content)
                    val path = "/interception/$runner/exchanges/${exchange.id}"
                    assertEquals(
                        200,
                        server.request(path, "POST", """{"action":"upstream","phase":"request"}""").statusCode()
                    )
                    assertEquals("upstream", exchange.awaitDecision { false }.action)
                    exchange.response(InterceptionResponse(200, emptyList(), "e30="))
                    assertEquals("SnapO.intercept.response", data(reader)["method"]?.jsonPrimitive?.content)
                    assertEquals(
                        409,
                        server.request(path, "POST", """{"action":"upstream","phase":"request"}""").statusCode()
                    )
                    assertEquals(
                        409,
                        server.request(path, "POST", """{"action":"upstream","phase":"response"}""").statusCode()
                    )
                    val decision = """{"action":"fulfill","phase":"response",
                        "response":{"status":201,"headerEntries":[],"body":"e30="}}"""
                    assertEquals(200, server.request(path, "POST", decision).statusCode())
                    assertEquals(201, exchange.awaitDecision { false }.response?.status)
                }
                assertEquals("SnapO.intercept.finished", data(reader)["method"]?.jsonPrimitive?.content)
                assertEquals(404, server.request("/interception/$runner", "DELETE").statusCode())
            }
        }
    }

    @Test
    fun `route replacement preserves existing exchanges and owners cannot resolve each other`() {
        val engine = NetworkInterception()
        Fixture(NetworkToolHttp(interception = engine)).use { server ->
            val first = server.stream("/interception", routes(), "POST")
            try {
                val owner = server.runnerId(first)
                val second = server.stream("/interception", routes("/other"), "POST")
                val other = server.runnerId(second)
                requireNotNull(engine.open("GET", "/api/profile")).use { exchange ->
                    exchange.request(
                        InterceptionRequest("GET", "https://example.test/api/profile", emptyList(), "")
                    )
                    data(first)
                    val decision = """{"action":"fail","phase":"request","error":"example"}"""
                    val suffix = "/exchanges/${exchange.id}"
                    assertEquals(409, server.request("/interception/$other$suffix", "POST", decision).statusCode())
                    assertEquals(
                        200,
                        server.request("/interception/$owner/routes", "PUT", routes("/new")).statusCode()
                    )
                    assertNull(engine.open("GET", "/api/profile"))
                    assertNotNull(engine.open("GET", "/new")?.also { it.close() })
                    assertEquals(200, server.request("/interception/$owner$suffix", "POST", decision).statusCode())
                    assertEquals("fail", exchange.awaitDecision { false }.action)
                }
                second.close()
            } finally {
                first.close()
            }
        }
    }

    @Test
    fun `closing the owning SSE socket fails all sixty four paused exchanges`() {
        val engine = NetworkInterception()
        Fixture(NetworkToolHttp(interception = engine)).use { server ->
            val reader = server.stream("/interception", routes(), "POST")
            val runner = server.runnerId(reader)
            val exchanges = List(64) { requireNotNull(engine.open("GET", "/api/profile")) }
            try {
                exchanges.forEach { exchange ->
                    exchange.request(InterceptionRequest("GET", "https://example.test/api/profile", emptyList(), ""))
                    assertEquals("SnapO.intercept.request", data(reader)["method"]?.jsonPrimitive?.content)
                }
                reader.close()
                exchanges.forEach { exchange ->
                    val failure = exchange.awaitDecision { false }
                    assertEquals("fail", failure.action)
                    assertEquals("Interception runner disconnected", failure.error)
                }
                assertNull(engine.open("GET", "/api/profile"))
                assertEquals(410, server.request("/interception/$runner/routes", "PUT", routes()).statusCode())
            } finally {
                reader.close()
                exchanges.forEach { it.close() }
            }
        }
    }

    @Test
    fun `multiple live subscriptions leave capacity for ordinary HTTP reads`() {
        val http = NetworkToolHttp()
        Fixture(http).use { server ->
            val streams = List(8) { server.stream("/network") }
            try {
                assertEquals(204, server.request("/", "OPTIONS").statusCode())
                assertEquals(200, server.request("/network").statusCode())
                http.broadcast(CdpMessage(method = "Network.loadingFinished", snapoSequence = 1))
                streams.forEach { reader ->
                    assertEquals("Network.loadingFinished", data(reader)["method"]?.jsonPrimitive?.content)
                }
            } finally {
                streams.forEach { it.close() }
            }
        }
    }

    @Test
    fun `invalid registration returns an HTTP error instead of starting an SSE response`() {
        Fixture(NetworkToolHttp()).use { server ->
            val response = server.request("/interception", "POST", """{"routes":[],"timeoutMs":30000}""")
            assertEquals(400, response.statusCode())
            assertTrue(response.headers().firstValue("Content-Type").get().startsWith("application/json"))
        }
    }

    @Test
    fun `HTTP parser rejects ambiguous framing and cross-origin mutations`() {
        for (headers in listOf(
            "Host: other\r\n",
            "Content-Length: -1\r\n",
            "Content-Length: 999999999\r\n",
            "Transfer-Encoding: chunked\r\n",
            "Origin: https://example.test\r\n",
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                PluginHttpRequest.read(
                    ByteArrayInputStream("POST /interception HTTP/1.1\r\nHost: localhost\r\n$headers\r\n".toByteArray())
                )
            }
        }
    }

    @Test
    fun `HTTP rejects rebinding hosts before reading data or accepting mutations`() = runBlocking {
        for (origin in listOf("", "Origin: http://attacker.example:1234\r\n", "Origin: http://localhost\r\n")) {
            for (method in listOf("GET", "POST", "OPTIONS")) {
                val output = ByteArrayOutputStream()
                val request = "$method /network HTTP/1.1\r\nHost: attacker.example:1234\r\n$origin\r\n"
                NetworkToolHttp().serveConnection(ByteArrayInputStream(request.toByteArray()), output)
                assertTrue(output.toString("UTF-8").startsWith("HTTP/1.1 400"))
            }
        }
    }

    @Test
    fun `browser preflight allows loopback origins and rejects remote or opaque origins`() = runBlocking {
        for (origin in listOf(
            "http://localhost",
            "http://127.0.0.1:5173",
            "http://[::1]:5173",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef"
        )) {
            val output = ByteArrayOutputStream()
            val request = "OPTIONS /interception HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n" +
                "Origin: $origin\r\nAccess-Control-Request-Method: PUT\r\n" +
                "Access-Control-Request-Headers: content-type\r\n\r\n"
            NetworkToolHttp().serveConnection(ByteArrayInputStream(request.toByteArray()), output)
            val response = output.toString("UTF-8")
            assertTrue(response.startsWith("HTTP/1.1 204"))
            assertTrue(response.contains("Access-Control-Allow-Origin: $origin\r\n"))
            assertTrue(response.contains("Access-Control-Expose-Headers: SnapO-Sequence, Location"))
        }
        for (origin in listOf(
            "null",
            "https://example.test",
            "http://localhost.example.test",
            "http://user@localhost",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef:1234",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef/",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef?q=1",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef#fragment",
            "snapo-inspector://user@01234567-89ab-cdef-0123-456789abcdef",
            "snapo-inspector://attacker.example"
        )) {
            val output = ByteArrayOutputStream()
            val request = "POST /interception HTTP/1.1\r\nHost: localhost\r\nOrigin: $origin\r\n\r\n"
            NetworkToolHttp().serveConnection(ByteArrayInputStream(request.toByteArray()), output)
            val response = output.toString("UTF-8")
            assertTrue(response.startsWith("HTTP/1.1 400"))
            assertTrue(!response.contains("Access-Control-Allow-Origin"))
        }
    }

    private fun routes(path: String = "/api/profile") =
        """{"routes":[{"id":"profile","method":"GET","path":"$path"}],"timeoutMs":30000}"""

    private fun data(reader: BufferedReader): JsonObject {
        while (true) {
            val line = checkNotNull(reader.readLine()) { "SSE ended before its next event" }
            if (line.startsWith(
                    "data: "
                )
            ) {
                return ProtocolJson.parseToJsonElement(line.removePrefix("data: ")).jsonObject
            }
        }
    }

    private fun request(
        path: String,
        method: String = "GET",
        accept: String = "*/*",
    ): Pair<String, String> = runBlocking {
        val request = "$method $path HTTP/1.1\r\nHost: localhost\r\nAccept: $accept\r\n\r\n"
        val output = ByteArrayOutputStream()
        NetworkToolHttp().serveConnection(ByteArrayInputStream(request.toByteArray()), output)
        val response = output.toString("UTF-8")
        response.substringBefore("\r\n") to response.substringAfter("\r\n\r\n")
    }

    private class Fixture(private val http: NetworkToolHttp) : Closeable {
        private val server = ServerSocket(0)
        private val executor = Executors.newCachedThreadPool()
        private val sockets = ConcurrentHashMap.newKeySet<Socket>()
        private val client = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build()
        private val locations = mutableMapOf<BufferedReader, String>()

        fun runnerId(reader: BufferedReader): String = requireNotNull(locations[reader]).removePrefix("/interception/")

        init {
            executor.submit {
                while (!server.isClosed) {
                    val socket = runCatching { server.accept() }.getOrNull() ?: break
                    sockets.add(socket)
                    executor.submit {
                        try {
                            runBlocking {
                                socket.soTimeout = 5000
                                http.serveConnection(
                                    socket.getInputStream(),
                                    socket.getOutputStream(),
                                    onRequestRead = { socket.soTimeout = 0 },
                                    closeConnection = { socket.close() }
                                )
                            }
                        } catch (_: CancellationException) {
                            // Closing the fixture cancels active event streams.
                        } finally {
                            sockets.remove(socket)
                            socket.close()
                        }
                    }
                }
            }
        }

        fun request(path: String, method: String = "GET", body: String = ""): HttpResponse<String> =
            client.send(build(path, method, body), HttpResponse.BodyHandlers.ofString())

        fun stream(path: String, body: String = "", method: String = "GET"): BufferedReader {
            val response = client.send(
                build(path, method, body, "text/event-stream"),
                HttpResponse.BodyHandlers.ofInputStream()
            )
            assertEquals(if (method == "POST") 201 else 200, response.statusCode())
            assertTrue(response.headers().firstValue("Content-Type").get().startsWith("text/event-stream"))
            assertEquals("http://localhost", response.headers().firstValue("Access-Control-Allow-Origin").get())
            return response.body().bufferedReader().also { reader ->
                response.headers().firstValue("Location").ifPresent { locations[reader] = it }
            }
        }

        private fun build(path: String, method: String, body: String, accept: String = "*/*"): HttpRequest =
            HttpRequest.newBuilder(URI("http://127.0.0.1:${server.localPort}$path"))
                .timeout(
                    Duration.ofSeconds(5)
                ).header(
                    "Content-Type",
                    "application/json"
                ).header("Accept", accept).header("Origin", "http://localhost")
                .method(
                    method,
                    if (body.isEmpty()) {
                        HttpRequest.BodyPublishers.noBody()
                    } else {
                        HttpRequest.BodyPublishers.ofString(
                            body
                        )
                    }
                ).build()

        override fun close() {
            http.close()
            sockets.forEach { it.close() }
            server.close()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}

private suspend fun NetworkToolHttp.serveConnection(
    input: java.io.InputStream,
    output: java.io.OutputStream,
    onRequestRead: () -> Unit = {},
    closeConnection: () -> Unit = {},
) = server.serve(object : PluginConnection {
    override val input = input
    override val output = output
    override fun setReadTimeout(millis: Int) { if (millis == 0) onRequestRead() }
    override fun close() = closeConnection()
})

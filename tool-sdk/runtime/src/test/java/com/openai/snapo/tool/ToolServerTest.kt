package com.openai.snapo.tool

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ToolServerTest {
    @Test
    fun `handler failures report 500 without exposing exception messages`() = runBlocking {
        val failures = listOf(
            IOException("private failure"),
            IllegalArgumentException("private failure"),
            java.net.SocketTimeoutException("private failure"),
        )
        for (failure in failures) {
            val server = ToolServer("example") { get("/failure") { throw failure } }
            val connection = MemoryConnection("GET /failure HTTP/1.1\r\nHost: localhost\r\n\r\n")
            server.serve(connection)
            assertTrue(connection.response.startsWith("HTTP/1.1 500"))
            assertFalse(connection.response.contains("private failure"))
            assertTrue(connection.response.contains("Internal server error"))
        }
    }

    @Test
    fun `routes decode parameters and repeated query values without changing plus in paths`() = runBlocking {
        val server = ToolServer("example") {
            get("/items/{id}") {
                assertEquals("a+b/c", pathParameters["id"])
                assertEquals("/items/a+b%2Fc?q=first+value&q=%2B", request.requestTarget)
                assertEquals("/items/a+b%2Fc", request.path)
                assertEquals(listOf("first value", "+"), request.queryParameters["q"])
                respondJson("{\"fake\":true}")
            }
        }
        val connection = MemoryConnection("GET /items/a+b%2Fc?q=first+value&q=%2B HTTP/1.1\r\nHost: localhost\r\n\r\n")
        server.serve(connection)
        assertTrue(connection.closed)
        assertTrue(connection.response.startsWith("HTTP/1.1 200 OK\r\n"))
        assertTrue(connection.response.endsWith("{\"fake\":true}"))
    }

    @Test
    fun `routing supplies preflight method errors and browser headers`() = runBlocking {
        val server = ToolServer("example") {
            get("/example") { respondText("fake") }
            post("/example") { respondNoContent() }
        }
        val origin = "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef"
        for ((method, path, status) in listOf(
            Triple("OPTIONS", "/", 204),
            Triple("DELETE", "/example", 405),
            Triple("GET", "/missing", 404)
        )) {
            val connection = MemoryConnection("$method $path HTTP/1.1\r\nHost: localhost\r\nOrigin: $origin\r\n\r\n")
            server.serve(connection)
            assertTrue(connection.response.startsWith("HTTP/1.1 $status"))
            assertTrue(connection.response.contains("Access-Control-Allow-Origin: $origin\r\n"))
            if (status == 405) assertTrue(connection.response.contains("Allow: GET, POST\r\n"))
        }
    }

    @Test
    fun `invalid requests are rejected before handlers run`() = runBlocking {
        var invoked = false
        val server = ToolServer("example") {
            requestPolicy = ToolHttpRequestPolicy(maxBodyBytes = 4)
            post("/example") {
                invoked = true
                respondNoContent()
            }
        }
        for ((headers, status) in listOf(
            "Host: example.test\r\n" to 400,
            "Host: localhost\r\nOrigin: https://example.test\r\n" to 400,
            "Host: localhost\r\nContent-Length: 5\r\n" to 413,
        )) {
            val connection = MemoryConnection("POST /example HTTP/1.1\r\n$headers\r\n")
            server.serve(connection)
            assertTrue(connection.response.startsWith("HTTP/1.1 $status"))
            assertFalse(connection.response.contains("Access-Control-Allow-Origin"))
        }
        assertFalse(invoked)
    }

    @Test
    fun `domain errors are customizable and errors after headers never produce a second response`() = runBlocking {
        val server = ToolServer("example") {
            onError { ToolHttpResponse.error(409, "Fake \"conflict\"\n") }
            get("/early") { throw IllegalStateException("Fake failure") }
            get("/late") {
                respondStream("application/x-ndjson") {
                    write("fake\n".toByteArray())
                    throw IOException("Fake disconnect")
                }
            }
        }
        val early = MemoryConnection("GET /early HTTP/1.1\r\nHost: localhost\r\n\r\n")
        server.serve(early)
        assertTrue(early.response.startsWith("HTTP/1.1 409"))
        assertTrue(early.response.endsWith("{\"error\":\"Fake \\\"conflict\\\"\\u000a\"}"))
        val late = MemoryConnection("GET /late HTTP/1.1\r\nHost: localhost\r\n\r\n")
        server.serve(late)
        assertEquals(1, Regex("HTTP/1.1").findAll(late.response).count())
        assertTrue(late.response.endsWith("5\r\nfake\n\r\n"))
    }

    @Test
    fun `finite streams have complete chunk framing`() = runBlocking {
        val server = ToolServer("example") {
            get("/snapshot") { respondStream("application/x-ndjson") { write("fake\n".toByteArray()) } }
        }
        val connection = MemoryConnection("GET /snapshot HTTP/1.1\r\nHost: localhost\r\n\r\n")
        server.serve(connection)
        assertTrue(connection.response.endsWith("5\r\nfake\n\r\n0\r\n\r\n"))
    }

    @Test
    fun `client disconnect cancels an SSE producer and its children`() = runBlocking {
        val entered = CountDownLatch(1)
        val childStopped = CountDownLatch(1)
        val producerStopped = CountDownLatch(1)
        val server = ToolServer("example") {
            sse("/events") {
                launch {
                    try {
                        entered.countDown()
                        awaitCancellation()
                    } finally { childStopped.countDown() }
                }
                try {
                    send("fake", event = "sample", id = "1")
                    awaitCancellation()
                } finally { producerStopped.countDown() }
            }
        }
        ServerSocket(0).use { listener ->
            Socket("127.0.0.1", listener.localPort).use { client ->
                val serving = async(Dispatchers.IO) { server.serve(TcpConnection(listener.accept())) }
                client.getOutputStream().write("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                try {
                    assertTrue(entered.await(5, TimeUnit.SECONDS))
                    client.close()
                    withTimeout(5000) { serving.join() }
                    assertTrue(producerStopped.await(5, TimeUnit.SECONDS))
                    assertTrue(childStopped.await(5, TimeUnit.SECONDS))
                } finally { serving.cancelAndJoin() }
            }
        }
    }

    @Test
    fun `returning from SSE ends child producers and completes chunk framing`() = runBlocking {
        val childStopped = CountDownLatch(1)
        val server = ToolServer("example") {
            sse("/events/{id}") {
                launch(start = CoroutineStart.UNDISPATCHED) {
                    try {
                        awaitCancellation()
                    } finally {
                        childStopped.countDown()
                    }
                }
                send(call.pathParameters.getValue("id"), event = "sample")
            }
        }
        ServerSocket(0).use { listener ->
            Socket("127.0.0.1", listener.localPort).use { client ->
                client.soTimeout = 5000
                val serving = async(Dispatchers.IO) { server.serve(TcpConnection(listener.accept())) }
                client.getOutputStream().write("GET /events/fake HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                try {
                    val response = client.getInputStream().bufferedReader().readText()
                    withTimeout(5000) { serving.join() }
                    assertTrue(response.contains("event: sample\ndata: fake\n\n"))
                    assertTrue(response.endsWith("0\r\n\r\n"))
                    assertTrue(childStopped.await(5, TimeUnit.SECONDS))
                } finally {
                    serving.cancelAndJoin()
                }
            }
        }
    }

    @Test
    fun `blocked writes close their connection instead of retaining an IO worker`() = runBlocking {
        val closed = CountDownLatch(1)
        val server = ToolServer("example") {
            get("/snapshot") { respondText("fake") }
        }
        val connection = object : ToolConnection {
            override val input = ByteArrayInputStream("GET /snapshot HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
            override val output = object : java.io.OutputStream() {
                override fun write(value: Int) {
                    check(closed.await(10, TimeUnit.SECONDS)) { "Write watchdog did not close the connection" }
                    throw IOException("Connection closed")
                }
            }
            override fun setReadTimeout(millis: Int) = Unit
            override fun close() { closed.countDown() }
        }
        val serving = async(Dispatchers.IO) { server.serve(connection) }
        try {
            withTimeout(10_000) { serving.join() }
            assertEquals(0L, closed.count)
        } finally {
            connection.close()
            serving.cancelAndJoin()
        }
    }

    private class MemoryConnection(request: String) : ToolConnection {
        override val input = ByteArrayInputStream(request.toByteArray())
        override val output = ByteArrayOutputStream()
        var closed = false
        val response get() = output.toString("UTF-8")
        override fun setReadTimeout(millis: Int) = Unit
        override fun close() { closed = true }
    }

    private class TcpConnection(private val socket: Socket) : ToolConnection {
        override val input get() = socket.getInputStream()
        override val output get() = socket.getOutputStream()
        override fun setReadTimeout(millis: Int) { socket.soTimeout = millis }
        override fun close() = socket.close()
    }
}

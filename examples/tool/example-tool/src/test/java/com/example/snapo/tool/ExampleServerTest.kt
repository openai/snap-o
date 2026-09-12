package com.example.snapo.tool

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import com.openai.snapo.tool.ToolConnection
import com.openai.snapo.tool.ToolServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.ServerSocket
import java.net.Socket

class ExampleServerTest {
    @Test
    fun `native readiness and browser preflight work`() {
        val origin = "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef"
        val response = request("OPTIONS", "/", "Origin: $origin\r\n")
        assertTrue(response.startsWith("HTTP/1.1 204 No Content\r\n"))
        assertTrue(response.contains("Access-Control-Allow-Origin: $origin\r\n"))
        assertTrue(response.contains("Access-Control-Allow-Methods: GET, POST\r\n"))
    }

    @Test
    fun `snapshot contains only fixed sample values`() {
        val first = request("GET", "/example")
        assertTrue(first.startsWith("HTTP/1.1 200 OK\r\n"))
        assertTrue(first.contains("Hello from Example"))
        assertEquals(first, request("GET", "/example"))
    }

    @Test
    fun `unknown routes unsupported methods and remote origins fail`() {
        assertTrue(request("GET", "/unknown").startsWith("HTTP/1.1 404"))
        assertTrue(request("POST", "/example").startsWith("HTTP/1.1 405"))
        val rejected = request("GET", "/example", "Origin: https://example.test\r\n")
        assertTrue(rejected.startsWith("HTTP/1.1 400"))
        assertFalse(rejected.contains("Access-Control-Allow-Origin"))
    }

    @Test
    fun `fake mutation updates both GET and an open SSE subscription`() = runBlocking {
        val server = exampleServer()
        ServerSocket(0).use { listener ->
            Socket("127.0.0.1", listener.localPort).use { client ->
                client.soTimeout = 5000
                val serving = async(Dispatchers.IO) {
                    val socket = listener.accept()
                    server.serve(object : ToolConnection {
                        override val input get() = socket.getInputStream()
                        override val output get() = socket.getOutputStream()
                        override fun setReadTimeout(millis: Int) { socket.soTimeout = millis }
                        override fun close() = socket.close()
                    })
                }
                try {
                    client.getOutputStream().write("GET /example/events HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                    val reader = client.getInputStream().bufferedReader()
                    fun snapshot(): String {
                        val data = mutableListOf<String>()
                        while (true) {
                            val line = reader.readLine() ?: error("Event stream ended before a snapshot")
                            if (line.startsWith("data: ")) data.add(line.removePrefix("data: "))
                            if (line.isEmpty() && data.isNotEmpty()) return data.joinToString("\n")
                        }
                    }
                    assertTrue(snapshot().contains("\"revision\":0"))
                    val changed = request("POST", "/example/increment", server = server)
                    assertTrue(changed.startsWith("HTTP/1.1 200"))
                    assertTrue(changed.contains("\"revision\":1"))
                    assertTrue(snapshot().contains("\"revision\":1"))
                    assertTrue(request("GET", "/example", server = server).contains("\"revision\":1"))
                    client.close()
                    withTimeout(5000) { serving.join() }
                } finally {
                    client.close()
                    serving.cancelAndJoin()
                }
            }
        }
    }

    private fun request(method: String, path: String, headers: String = "", server: ToolServer = exampleServer()): String {
        val output = ByteArrayOutputStream()
        val input = "$method $path HTTP/1.1\r\nHost: localhost\r\n$headers\r\n"
        runBlocking {
            server.serve(object : ToolConnection {
                override val input = ByteArrayInputStream(input.toByteArray())
                override val output = output
                override fun setReadTimeout(millis: Int) = Unit
                override fun close() = Unit
            })
        }
        return output.toString("UTF-8")
    }
}

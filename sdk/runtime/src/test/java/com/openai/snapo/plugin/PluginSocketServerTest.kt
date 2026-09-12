package com.openai.snapo.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class PluginSocketServerTest {
    @Test
    fun `disallowed startup never binds or reports a socket failure`() {
        PluginSocketServer(1, { error("Must not bind") }) {}.use { server ->
            assertFalse(server.startIfAllowed(false) { error("Must not report a failure") })
            assertFalse(server.isRunning)
        }
    }

    @Test
    fun `guarded startup reports bind failures and permits retry without duplicate listeners`() {
        val binds = AtomicInteger()
        val failure = IOException("Synthetic bind failure")
        val failures = mutableListOf<IOException>()
        val listener = TcpListener()
        PluginSocketServer(1, {
            if (binds.incrementAndGet() == 1) throw failure
            listener
        }) {}.use { server ->
            assertFalse(server.startIfAllowed(true, failures::add))
            assertFalse(server.isRunning)
            assertEquals(listOf(failure), failures)
            assertTrue(server.startIfAllowed(true, failures::add))
            assertTrue(server.startIfAllowed(true, failures::add))
            assertTrue(server.isRunning)
            assertEquals(2, binds.get())
            server.close()
            assertTrue(listener.isClosed)
            assertFalse(server.isRunning)
        }
    }

    @Test
    fun `guarded startup does not hide programming errors`() {
        PluginSocketServer(1, { throw IllegalArgumentException("Invalid socket configuration") }) {}.use { server ->
            assertThrows(IllegalArgumentException::class.java) {
                server.startIfAllowed(true) { error("Must not report a socket failure") }
            }
        }
    }

    @Test
    fun `start is idempotent and close releases a blocked reader and listener`() {
        val listener = TcpListener()
        val entered = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val binds = AtomicInteger()
        val server = PluginSocketServer(1, {
            binds.incrementAndGet()
            listener
        }) { connection ->
            entered.countDown()
            try {
                connection.input.read()
            } finally {
                finished.countDown()
            }
        }
        server.use {
            server.start()
            server.start()
            assertEquals(1, binds.get())
            assertTrue(server.isRunning)
            listener.connect().use { client ->
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                server.close()
                assertEquals(-1, client.getInputStream().read())
                assertTrue(finished.await(5, TimeUnit.SECONDS))
                assertFalse(server.isRunning)
                assertTrue(listener.isClosed)
            }
        }
    }

    @Test
    fun `connection limits reject excess clients without disturbing an active request`() {
        val listener = TcpListener()
        val entered = CountDownLatch(1)
        PluginSocketServer(1, { listener }) { connection ->
            entered.countDown()
            val byte = connection.input.read()
            connection.output.write(byte)
            connection.output.flush()
        }.use { server ->
            server.start()
            listener.connect().use { first ->
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                listener.connect().use { excess -> assertEquals(-1, excess.getInputStream().read()) }
                first.getOutputStream().write(42)
                first.getOutputStream().flush()
                assertEquals(42, first.getInputStream().read())
                assertEquals(-1, first.getInputStream().read())
            }
        }
    }

    @Test
    fun `failed bindings can be retried and closed servers can start a fresh session`() {
        val listeners = mutableListOf<TcpListener>()
        val binds = AtomicInteger()
        PluginSocketServer(2, {
            if (binds.incrementAndGet() == 1) throw IOException("Synthetic bind failure")
            TcpListener().also { listeners.add(it) }
        }) { connection ->
            val request = PluginHttpRequest.read(connection.input)
            if (request.path == "/fail") throw IOException("Synthetic handler failure")
            PluginHttpResponse(200, "hello".toByteArray()).write(connection.output)
        }.use { server ->
            assertThrows(IOException::class.java) { server.start() }
            assertFalse(server.isRunning)
            repeat(2) {
                server.start()
                val listener = listeners.last()
                listener.connect().use { failed ->
                    failed.getOutputStream().write("GET /fail HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                    assertEquals(-1, failed.getInputStream().read())
                }
                listener.connect().use { client ->
                    client.getOutputStream().write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                    val response = client.getInputStream().bufferedReader().readText()
                    assertTrue(response.startsWith("HTTP/1.1 200 OK\r\n"))
                    assertTrue(response.endsWith("hello"))
                }
                server.close()
                assertTrue(listener.isClosed)
            }
        }
    }

    @Test
    fun `socket names follow the inspector discovery contract`() {
        assertEquals("snapo_example.inspector-v2_123", PluginSocketServer.socketName("example.inspector-v2", 123))
        for (id in listOf("", "Uppercase", "with_underscore", "a".repeat(101), "../example")) {
            assertThrows(IllegalArgumentException::class.java) { PluginSocketServer.socketName(id, 123) }
        }
        assertThrows(IllegalArgumentException::class.java) { PluginSocketServer.socketName("example", 0) }
    }

    private class TcpListener : PluginSocketListener {
        private val socket = ServerSocket(0)
        val isClosed: Boolean get() = socket.isClosed
        fun connect(): Socket = Socket("127.0.0.1", socket.localPort).apply { soTimeout = 5000 }
        override fun close() = socket.close()
        override fun accept(): PluginConnection = TcpConnection(socket.accept())
    }

    private class TcpConnection(private val socket: Socket) : PluginConnection {
        override val input get() = socket.getInputStream()
        override val output get() = socket.getOutputStream()
        override fun setReadTimeout(millis: Int) { socket.soTimeout = millis }
        override fun close() = socket.close()
    }
}

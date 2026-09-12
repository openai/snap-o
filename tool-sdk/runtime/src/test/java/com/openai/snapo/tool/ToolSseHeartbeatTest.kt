package com.openai.snapo.tool

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

@OptIn(ExperimentalCoroutinesApi::class)
class ToolSseHeartbeatTest {
    @Test
    fun `both SSE entry points send automatic comments at 30 seconds and stop on cancellation`() = runTest {
        val server = ToolServer("example") {
            sse("/events") { awaitCancellation() }
            get("/direct") { respondSse { awaitCancellation() } }
        }
        for (path in listOf("/events", "/direct")) {
            val connection = Connection(path)
            val serving = launch { server.serve(connection) }
            try {
                runCurrent()
                advanceTimeBy(29_999)
                runCurrent()
                assertEquals(0, connection.heartbeats)
                advanceTimeBy(1)
                runCurrent()
                assertEquals(1, connection.heartbeats)
                assertTrue(connection.response.endsWith("e\r\n: keep-alive\n\n\r\n"))
                advanceTimeBy(30_000)
                runCurrent()
                assertEquals(2, connection.heartbeats)
            } finally {
                serving.cancelAndJoin()
            }
            val finished = connection.response
            advanceTimeBy(60_000)
            runCurrent()
            assertEquals(finished, connection.response)
            assertTrue(connection.closed)
        }
    }

    @Test
    fun `streams can override the interval or disable automatic comments`() = runTest {
        val server = ToolServer("example") {
            sse("/fast", heartbeatInterval = 5.seconds) { awaitCancellation() }
            sse("/silent", heartbeatInterval = null) { awaitCancellation() }
        }
        val fast = Connection("/fast")
        val silent = Connection("/silent")
        val fastJob = launch { server.serve(fast) }
        val silentJob = launch { server.serve(silent) }
        try {
            runCurrent()
            advanceTimeBy(60_000)
            runCurrent()
            assertEquals(12, fast.heartbeats)
            assertEquals(0, silent.heartbeats)
        } finally {
            fastJob.cancelAndJoin()
            silentJob.cancelAndJoin()
        }
    }

    @Test
    fun `returning from a producer cancels its heartbeat before the terminating chunk`() = runTest {
        val server = ToolServer("example") {
            sse("/events", heartbeatInterval = 5.seconds) {
                send("fake")
                delay(6.seconds)
            }
        }
        val connection = Connection("/events")
        val serving = launch { server.serve(connection) }
        try {
            runCurrent()
            advanceTimeBy(6_000)
            runCurrent()
            serving.join()
            assertEquals(1, connection.heartbeats)
            assertTrue(connection.response.endsWith("0\r\n\r\n"))
            val finished = connection.response
            advanceTimeBy(60_000)
            runCurrent()
            assertEquals(finished, connection.response)
        } finally {
            serving.cancelAndJoin()
        }
    }

    @Test
    fun `invalid intervals fail before a stream starts`() {
        for (interval in listOf(Duration.ZERO, (-1).seconds, Duration.INFINITE)) {
            assertThrows(IllegalArgumentException::class.java) {
                ToolServer("example") { sse("/events", heartbeatInterval = interval) {} }
            }
        }
    }

    private class Connection(path: String) : ToolConnection {
        private val disconnected = CountDownLatch(1)
        private val head = ByteArrayInputStream("GET $path HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
        override val input = object : InputStream() {
            override fun read(): Int {
                val next = head.read()
                if (next >= 0) return next
                disconnected.await()
                return -1
            }
        }
        override val output = ByteArrayOutputStream()
        val closed get() = disconnected.count == 0L
        val response get() = output.toString("UTF-8")
        val heartbeats get() = Regex(": keep-alive\\n\\n").findAll(response).count()
        override fun setReadTimeout(millis: Int) = Unit
        override fun close() { disconnected.countDown() }
    }
}

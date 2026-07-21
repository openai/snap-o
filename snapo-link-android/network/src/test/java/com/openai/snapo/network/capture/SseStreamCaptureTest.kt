package com.openai.snapo.network.capture

import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.ResponseStreamClosed
import com.openai.snapo.network.ResponseStreamEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class SseStreamCaptureTest {

    @Test
    fun `events remain framed when utf8 and crlf boundaries split across reads`() {
        val records = mutableListOf<NetworkEventRecord>()
        val capture = capture(records)
        val bytes = "data: 😀\r\n\r\ndata: second\n\n".encodeToByteArray()

        bytes.forEach { byte -> capture.append(byteArrayOf(byte)) }
        capture.complete()

        assertEquals(
            listOf("data: 😀", "data: second"),
            records.filterIsInstance<ResponseStreamEvent>().map(ResponseStreamEvent::raw),
        )
        assertEquals(
            listOf(1L, 2L),
            records.filterIsInstance<ResponseStreamEvent>().map(ResponseStreamEvent::sequence),
        )
        val closed = records.filterIsInstance<ResponseStreamClosed>().single()
        assertEquals(2L, closed.totalEvents)
        assertEquals(bytes.size.toLong(), closed.totalBytes)
    }

    @Test
    fun `complete flushes tail before one close record`() {
        val records = mutableListOf<NetworkEventRecord>()
        val capture = capture(records)

        capture.append("data: tail".encodeToByteArray())
        capture.complete()
        capture.complete(IOException("ignored"))
        capture.append("\n\n".encodeToByteArray())

        assertTrue(records[0] is ResponseStreamEvent)
        assertEquals("data: tail", (records[0] as ResponseStreamEvent).raw)
        val closed = records[1] as ResponseStreamClosed
        assertEquals("completed", closed.reason)
        assertEquals(1L, closed.totalEvents)
        assertEquals("data: tail".encodeToByteArray().size.toLong(), closed.totalBytes)
        assertEquals(2, records.size)
    }

    @Test
    fun `append honors byte ranges and error details`() {
        val records = mutableListOf<NetworkEventRecord>()
        val capture = capture(records)
        val source = "ignoreddata: kept\n\nignored".encodeToByteArray()
        val selected = "data: kept\n\n".encodeToByteArray()

        capture.append(source, offset = "ignored".length, length = selected.size)
        capture.complete(IOException("stream failed"))

        assertEquals("data: kept", records.filterIsInstance<ResponseStreamEvent>().single().raw)
        val closed = records.filterIsInstance<ResponseStreamClosed>().single()
        assertEquals("error", closed.reason)
        assertEquals("stream failed", closed.message)
        assertEquals(selected.size.toLong(), closed.totalBytes)
    }

    @Test
    fun `empty stream emits only a close record`() {
        val records = mutableListOf<NetworkEventRecord>()

        capture(records).complete()

        val closed = records.single() as ResponseStreamClosed
        assertEquals(0L, closed.totalEvents)
        assertEquals(0L, closed.totalBytes)
    }

    @Test
    fun `observer failures are isolated and later records are still delivered`() {
        val records = mutableListOf<NetworkEventRecord>()
        var callbackCount = 0
        val capture = capture { record ->
            callbackCount += 1
            if (callbackCount == 1) error("observer failed")
            records += record
        }

        capture.append("data: first\n\ndata: second\n\n".encodeToByteArray())
        capture.complete()

        assertEquals("data: second", records.filterIsInstance<ResponseStreamEvent>().single().raw)
        assertEquals(2L, records.filterIsInstance<ResponseStreamClosed>().single().totalEvents)
    }

    @Test
    fun `concurrent close is delivered after an in-flight event`() {
        val records = mutableListOf<NetworkEventRecord>()
        val eventEntered = CountDownLatch(1)
        val releaseEvent = CountDownLatch(1)
        val eventReleased = AtomicBoolean(false)
        val capture = capture { record ->
            if (record is ResponseStreamEvent) {
                eventEntered.countDown()
                eventReleased.set(releaseEvent.await(5, TimeUnit.SECONDS))
            }
            records += record
        }
        val appendThread = Thread {
            capture.append("data: event\n\n".encodeToByteArray())
        }
        val closeThread = Thread(capture::complete)

        appendThread.start()
        assertTrue(eventEntered.await(5, TimeUnit.SECONDS))
        closeThread.start()
        releaseEvent.countDown()
        appendThread.join()
        closeThread.join()

        assertTrue(eventReleased.get())
        assertTrue(records[0] is ResponseStreamEvent)
        assertTrue(records[1] is ResponseStreamClosed)
    }

    @Test
    fun `decoder handles output buffers and incomplete final characters`() {
        val records = mutableListOf<NetworkEventRecord>()
        val capture = capture(records)
        val longEvent = "data: " + "x".repeat(2_048)
        val incompleteUtf8 = byteArrayOf(0xF0.toByte(), 0x9F.toByte())

        capture.append("$longEvent\n\n".encodeToByteArray())
        capture.append(incompleteUtf8)
        capture.complete()

        val events = records.filterIsInstance<ResponseStreamEvent>()
        assertEquals(longEvent, events[0].raw)
        assertEquals("\uFFFD", events[1].raw)
    }

    private fun capture(records: MutableList<NetworkEventRecord>): SseStreamCapture {
        return capture(records::add)
    }

    private fun capture(onRecord: (NetworkEventRecord) -> Unit): SseStreamCapture {
        var wallTime = 100L
        var monotonicTime = 200L
        return SseStreamCapture(
            requestId = "request",
            charset = Charsets.UTF_8,
            onRecord = onRecord,
            wallTimeMillis = { wallTime++ },
            monotonicNanos = { monotonicTime++ },
        )
    }
}

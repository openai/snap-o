package com.openai.snapo.network.okhttp3

import com.openai.snapo.network.capture.RawResponseBodyCapture
import okhttp3.Headers
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.TrailersSource
import okio.Buffer
import okio.BufferedSink
import okio.BufferedSource
import okio.ForwardingSource
import okio.Source
import okio.Timeout
import okio.buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException

class BodyCaptureTest {

    @Test
    fun `request body is serialized once and captured from the real write`() {
        val delegate = CountingRequestBody("request body")
        var capture: RequestBodyCapture? = null
        val body = CapturingRequestBody(delegate = delegate, maxBytes = 4) { value ->
            capture = value
        }
        val sink = Buffer()

        body.writeTo(sink)

        assertEquals("request body", sink.readUtf8())
        assertEquals(1, delegate.writeCount)
        val captured = checkNotNull(capture)
        assertArrayEquals("requ".encodeToByteArray(), captured.body)
        assertEquals(12L, captured.totalBytes)
        assertEquals(8L, captured.truncatedBytes)
    }

    @Test
    fun `request capture does not add a network flush`() {
        val upstream = FlushCountingSink()
        val networkSink = upstream.buffer()
        val body = CapturingRequestBody(CountingRequestBody("request body"), maxBytes = 4) { }

        body.writeTo(networkSink)

        assertEquals(0, upstream.flushCount)
        networkSink.emit()
        assertEquals("request body", upstream.received.readUtf8())
    }

    @Test
    fun `request observer failure cannot break the network write`() {
        val sink = Buffer()
        val body = CapturingRequestBody(CountingRequestBody("request body"), maxBytes = 4) {
            error("observer failed")
        }

        body.writeTo(sink)

        assertEquals("request body", sink.readUtf8())
    }

    @Test
    fun `response body is not read until the caller consumes it`() {
        val delegate = TrackingResponseBody("response body")
        val captures = mutableListOf<RawResponseBodyCapture>()
        val body = CapturingResponseBody(delegate = delegate, maxBytes = 4) { capture, error ->
            assertNull(error)
            captures += capture
        }

        val firstSource = body.source()

        assertEquals(0, delegate.readCount)
        assertSame(firstSource, body.source())
        assertEquals("response body", body.string())
        assertTrue(delegate.readCount > 0)
        assertEquals(1, captures.size)
        assertArrayEquals("resp".encodeToByteArray(), captures.single().bytes)
        assertEquals(13L, captures.single().totalBytes)
        assertTrue(captures.single().reachedEof)
    }

    @Test
    fun `reading trailers first still passes the response through the capture tee`() {
        val captures = mutableListOf<RawResponseBodyCapture>()
        val body = CapturingResponseBody(TrackingResponseBody("response body"), maxBytes = 4) { capture, _ ->
            captures += capture
        }
        val trailers = Headers.Builder().add("X-Trailer", "done").build()
        val response = Response.Builder()
            .request(Request.Builder().url("https://example.com/response").build())
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body)
            .trailers(
                object : TrailersSource {
                    override fun get(): Headers = trailers
                },
            )
            .build()
        val wrapped = response.newBuilder()
            .trailers(capturingTrailersSource(response, body))
            .build()

        assertEquals(trailers, wrapped.trailers())
        assertEquals(1, captures.size)
        assertEquals(13L, captures.single().totalBytes)
        assertTrue(captures.single().reachedEof)
    }

    @Test
    fun `zero response capture limit still preserves the caller body`() {
        var capture: RawResponseBodyCapture? = null
        val body = CapturingResponseBody(TrackingResponseBody("complete"), maxBytes = 0) { value, _ ->
            capture = value
        }

        assertEquals("complete", body.string())
        val captured = checkNotNull(capture)
        assertArrayEquals(ByteArray(0), captured.bytes)
        assertEquals(8L, captured.totalBytes)
    }

    @Test
    fun `observer failure cannot break a successful response read`() {
        val body = CapturingResponseBody(TrackingResponseBody("complete"), maxBytes = 4) { _, _ ->
            error("observer failed")
        }

        assertEquals("complete", body.string())
    }

    @Test
    fun `observer failure cannot replace the upstream response failure`() {
        val expected = IOException("upstream failed")
        val body = CapturingResponseBody(FailingResponseBody(expected), maxBytes = 4) { _, _ ->
            error("observer failed")
        }

        try {
            body.source().read(Buffer(), 1L)
            fail("Expected the upstream failure")
        } catch (error: IOException) {
            assertSame(expected, error)
        }
    }

    @Test
    fun `closing a partially consumed response completes once without claiming eof`() {
        val captures = mutableListOf<RawResponseBodyCapture>()
        val delegate = TrackingResponseBody("response body")
        val body = CapturingResponseBody(delegate, maxBytes = 4) { capture, _ ->
            captures += capture
        }
        val sink = Buffer()

        body.source().read(sink, 2L)
        val readCount = delegate.readCount
        body.close()
        body.close()

        assertTrue(readCount > 0)
        assertEquals(readCount, delegate.readCount)
        assertEquals(1, captures.size)
        assertFalse(captures.single().reachedEof)
    }

    private class CountingRequestBody(private val value: String) : RequestBody() {
        var writeCount: Int = 0
            private set

        override fun contentType(): MediaType? = null

        override fun writeTo(sink: BufferedSink) {
            writeCount += 1
            sink.writeUtf8(value)
        }
    }

    private class TrackingResponseBody(value: String) : ResponseBody() {
        private val contentLength = value.encodeToByteArray().size.toLong()
        private val upstream = Buffer().writeUtf8(value)
        private val trackedSource: BufferedSource = object : ForwardingSource(upstream) {
            override fun read(sink: Buffer, byteCount: Long): Long {
                readCount += 1
                return super.read(sink, byteCount)
            }
        }.buffer()

        var readCount: Int = 0
            private set

        override fun contentType(): MediaType = "text/plain; charset=utf-8".toMediaType()

        override fun contentLength(): Long = contentLength

        override fun source(): BufferedSource = trackedSource
    }

    private class FailingResponseBody(private val failure: IOException) : ResponseBody() {
        private val failingSource: BufferedSource = object : Source {
            override fun read(sink: Buffer, byteCount: Long): Long = throw failure
            override fun timeout(): Timeout = Timeout.NONE
            override fun close() = Unit
        }.buffer()

        override fun contentType(): MediaType = "text/plain".toMediaType()

        override fun contentLength(): Long = -1L

        override fun source(): BufferedSource = failingSource
    }

    private class FlushCountingSink : okio.Sink {
        val received = Buffer()
        var flushCount: Int = 0
            private set

        override fun write(source: Buffer, byteCount: Long) {
            received.write(source, byteCount)
        }

        override fun flush() {
            flushCount += 1
        }

        override fun timeout(): Timeout = Timeout.NONE

        override fun close() = Unit
    }
}

package com.openai.snapo.network.okhttp3

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
import java.util.Base64

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
        val captures = mutableListOf<ResponseBodyCapture>()
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
        assertArrayEquals("resp".encodeToByteArray(), captures.single().body)
        assertEquals(13L, captures.single().totalBytes)
        assertTrue(captures.single().reachedEof)
    }

    @Test
    fun `reading trailers first still passes the response through the capture tee`() {
        val captures = mutableListOf<ResponseBodyCapture>()
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
        var capture: ResponseBodyCapture? = null
        val body = CapturingResponseBody(TrackingResponseBody("complete"), maxBytes = 0) { value, _ ->
            capture = value
        }

        assertEquals("complete", body.string())
        val captured = checkNotNull(capture)
        assertArrayEquals(ByteArray(0), captured.body)
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
    fun `response formatter applies body and preview limits after capture`() {
        val capture = ResponseBodyCapture(
            body = "0123456789".encodeToByteArray(),
            totalBytes = 10L,
            reachedEof = true,
        )

        val text = resolveResponseBodyCapture(
            capture = capture,
            contentType = "text/plain; charset=utf-8".toMediaType(),
            textBodyMaxBytes = 4,
            binaryBodyMaxBytes = 6,
            previewBytes = 2,
            declaredBodySize = null,
        )
        val binary = resolveResponseBodyCapture(
            capture = capture,
            contentType = "application/octet-stream".toMediaType(),
            textBodyMaxBytes = 4,
            binaryBodyMaxBytes = 6,
            previewBytes = 2,
            declaredBodySize = null,
        )
        val omitted = resolveResponseBodyCapture(
            capture = capture,
            contentType = "text/plain".toMediaType(),
            textBodyMaxBytes = 0,
            binaryBodyMaxBytes = 0,
            previewBytes = 2,
            declaredBodySize = null,
        )

        assertEquals("0123", text.body)
        assertEquals("01", text.preview)
        assertEquals(null, text.encoding)
        assertEquals(6L, text.truncatedBytes)
        assertEquals("MDEyMzQ1", binary.body)
        assertEquals("MDE=", binary.preview)
        assertEquals("base64", binary.encoding)
        assertEquals(4L, binary.truncatedBytes)
        assertNull(omitted.body)
        assertEquals("01", omitted.preview)
        assertEquals(10L, omitted.truncatedBytes)
    }

    @Test
    fun `known text response smaller than the complete-body threshold is retained in full`() {
        val bodySize = 7_000_000
        val bytes = ByteArray(bodySize) { 'a'.code.toByte() }
        val capture = ResponseBodyCapture(body = bytes, totalBytes = bodySize.toLong(), reachedEof = true)

        val resolved = resolveResponseBodyCapture(
            capture = capture,
            contentType = "text/plain; charset=utf-8".toMediaType(),
            textBodyMaxBytes = DefaultTextBodyMaxBytes,
            binaryBodyMaxBytes = DefaultBinaryBodyMaxBytes,
            previewBytes = DefaultBodyPreviewBytes,
            declaredBodySize = bodySize.toLong(),
        )

        val body = checkNotNull(resolved.body)
        assertEquals(bodySize, body.length)
        assertTrue(body.all { it == 'a' })
        assertEquals("a".repeat(DefaultBodyPreviewBytes), resolved.preview)
        assertNull(resolved.encoding)
        assertNull(resolved.truncatedBytes)
        assertEquals(bodySize.toLong(), resolved.bodySize)
    }

    @Test
    fun `known binary response smaller than the complete-body threshold is retained in full`() {
        val bodySize = 7_000_000
        val bytes = ByteArray(bodySize) { index -> index.toByte() }
        val capture = ResponseBodyCapture(body = bytes, totalBytes = bodySize.toLong(), reachedEof = true)

        val resolved = resolveResponseBodyCapture(
            capture = capture,
            contentType = "application/octet-stream".toMediaType(),
            textBodyMaxBytes = DefaultTextBodyMaxBytes,
            binaryBodyMaxBytes = DefaultBinaryBodyMaxBytes,
            previewBytes = DefaultBodyPreviewBytes,
            declaredBodySize = bodySize.toLong(),
        )

        assertArrayEquals(bytes, Base64.getDecoder().decode(checkNotNull(resolved.body)))
        assertEquals(
            Base64.getEncoder().encodeToString(bytes.copyOf(DefaultBodyPreviewBytes)),
            resolved.preview,
        )
        assertEquals("base64", resolved.encoding)
        assertNull(resolved.truncatedBytes)
        assertEquals(bodySize.toLong(), resolved.bodySize)
    }

    @Test
    fun `known response larger than the complete-body threshold remains limited`() {
        val bodySize = 8L * 1024L * 1024L + 1L
        val captureLimit = DefaultTextBodyMaxBytes
        val capture = ResponseBodyCapture(
            body = ByteArray(captureLimit) { 'a'.code.toByte() },
            totalBytes = bodySize,
            reachedEof = true,
        )

        val resolved = resolveResponseBodyCapture(
            capture = capture,
            contentType = "text/plain; charset=utf-8".toMediaType(),
            textBodyMaxBytes = captureLimit,
            binaryBodyMaxBytes = DefaultBinaryBodyMaxBytes,
            previewBytes = DefaultBodyPreviewBytes,
            declaredBodySize = bodySize,
        )

        assertEquals(captureLimit, checkNotNull(resolved.body).length)
        assertEquals(DefaultBodyPreviewBytes, checkNotNull(resolved.preview).length)
        assertNull(resolved.encoding)
        assertEquals(bodySize - captureLimit, resolved.truncatedBytes)
        assertEquals(bodySize, resolved.bodySize)
    }

    @Test
    fun `unknown-length response remains limited`() {
        val captureLimit = 1_024
        val bodySize = captureLimit + 257L
        val capture = ResponseBodyCapture(
            body = ByteArray(captureLimit) { 'a'.code.toByte() },
            totalBytes = bodySize,
            reachedEof = true,
        )

        val resolved = resolveResponseBodyCapture(
            capture = capture,
            contentType = "text/plain; charset=utf-8".toMediaType(),
            textBodyMaxBytes = captureLimit,
            binaryBodyMaxBytes = DefaultBinaryBodyMaxBytes,
            previewBytes = 16,
            declaredBodySize = null,
        )

        assertEquals(captureLimit, checkNotNull(resolved.body).length)
        assertEquals(16, checkNotNull(resolved.preview).length)
        assertNull(resolved.encoding)
        assertEquals(bodySize - captureLimit, resolved.truncatedBytes)
        assertEquals(bodySize, resolved.bodySize)
    }

    @Test
    fun `closing a partially consumed response completes once without claiming eof`() {
        val captures = mutableListOf<ResponseBodyCapture>()
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

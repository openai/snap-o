package com.openai.snapo.network.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class BodyCapturePolicyTest {

    @Test
    fun `content types share text stream multipart and charset classification`() {
        val json = BodyContentType.parse("Application/Problem+Json; charset=\"UTF-16\"")
        val stream = BodyContentType.parse("text/event-stream; charset=not-a-charset")
        val multipart = BodyContentType.parse("multipart/form-data; boundary=abc")

        assertTrue(checkNotNull(json).isTextLike)
        assertEquals(Charsets.UTF_16, json.charsetOrUtf8())
        assertTrue(checkNotNull(stream).isTextLike)
        assertTrue(stream.isEventStream)
        assertEquals(Charsets.UTF_8, stream.charsetOrUtf8())
        assertTrue(checkNotNull(multipart).isTextLike)
        assertTrue(multipart.isMultipartFormData)
        assertNull(BodyContentType.parse("invalid"))
    }

    @Test
    fun `capture limits use shared text binary preview and known length policy`() {
        val text = BodyContentType.parse("text/plain")
        val binary = BodyContentType.parse("application/octet-stream")

        assertEquals(100, resolveRequestCaptureLimit(text, null, 100, 20))
        assertEquals(20, resolveRequestCaptureLimit(binary, null, 100, 20))
        assertEquals(20, resolveRequestCaptureLimit(text, "gzip", 100, 20))
        assertEquals(
            120,
            resolveResponseCaptureLimit(text, null, textBodyMaxBytes = 40, binaryBodyMaxBytes = 80, previewBytes = 120),
        )
        assertEquals(
            80,
            resolveResponseCaptureLimit(null, null, textBodyMaxBytes = 40, binaryBodyMaxBytes = 80, previewBytes = 10),
        )
        assertEquals(
            7_000_000,
            resolveResponseCaptureLimit(
                contentType = text,
                contentLength = 7_000_000L,
                textBodyMaxBytes = 1_024,
                binaryBodyMaxBytes = 1_024,
                previewBytes = 16,
            ),
        )
        assertEquals(7_000_000, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 7_000_000L))
        assertEquals(1_024, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 9L * 1024L * 1024L))
        assertEquals(0, resolveEffectiveMaxBytes(maxBytes = -1, contentLength = null))
    }

    @Test
    fun `request bodies share text binary compression and empty body encoding`() {
        val text = BodyContentType.parse("text/plain; charset=utf-8")
        val binary = BodyContentType.parse("application/octet-stream")

        assertEquals(
            ResolvedRequestBody(body = "hello", encoding = null),
            resolveRequestBody("hello".encodeToByteArray(), text, contentEncoding = null),
        )
        assertEquals(
            ResolvedRequestBody(
                body = Base64.getEncoder().encodeToString("hello".encodeToByteArray()),
                encoding = "base64",
            ),
            resolveRequestBody("hello".encodeToByteArray(), binary, contentEncoding = null),
        )
        assertEquals(
            "base64",
            resolveRequestBody(ByteArray(0), text, contentEncoding = "br").encoding,
        )
        assertNull(resolveRequestBody(ByteArray(0), text, contentEncoding = null).body)
        assertNull(
            resolveRequestBody(
                bytes = null,
                contentType = null,
                contentEncoding = null,
                hasBody = false,
            ).encoding,
        )
    }

    @Test
    fun `response bodies share text binary preview and truncation policy`() {
        val capture = RawResponseBodyCapture(
            bytes = "0123456789".encodeToByteArray(),
            totalBytes = 10L,
            reachedEof = true,
        )

        val text = resolveResponseBody(
            capture = capture,
            contentType = BodyContentType.parse("text/plain; charset=utf-8"),
            textBodyMaxBytes = 4,
            binaryBodyMaxBytes = 6,
            previewBytes = 2,
            declaredBodySize = null,
        )
        val binary = resolveResponseBody(
            capture = capture,
            contentType = BodyContentType.parse("application/octet-stream"),
            textBodyMaxBytes = 4,
            binaryBodyMaxBytes = 6,
            previewBytes = 2,
            declaredBodySize = null,
        )
        val omitted = resolveResponseBody(
            capture = capture,
            contentType = BodyContentType.parse("text/plain"),
            textBodyMaxBytes = 0,
            binaryBodyMaxBytes = 0,
            previewBytes = 2,
            declaredBodySize = null,
        )

        assertEquals("0123", text.body)
        assertEquals("01", text.preview)
        assertNull(text.encoding)
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
    fun `unknown content uses utf8 sniffing and partial close uses declared size`() {
        val text = resolveResponseBody(
            capture = RawResponseBodyCapture(
                bytes = "printable".encodeToByteArray(),
                totalBytes = 9L,
                reachedEof = true,
            ),
            contentType = null,
            textBodyMaxBytes = 20,
            binaryBodyMaxBytes = 4,
            previewBytes = 4,
            declaredBodySize = null,
        )
        val partial = resolveResponseBody(
            capture = RawResponseBodyCapture(
                bytes = byteArrayOf(0, 1, 2, 3),
                totalBytes = 4L,
                reachedEof = false,
            ),
            contentType = null,
            textBodyMaxBytes = 20,
            binaryBodyMaxBytes = 2,
            previewBytes = 2,
            declaredBodySize = 10L,
        )

        assertEquals("printable", text.body)
        assertNull(text.encoding)
        assertEquals(10L, partial.bodySize)
        assertEquals(6L, partial.truncatedBytes)
        assertEquals("base64", partial.encoding)
    }

    @Test
    fun `large and unknown length responses remain limited`() {
        val captureLimit = 1_024
        val knownBodySize = 8L * 1024L * 1024L + 1L
        val contentType = BodyContentType.parse("text/plain; charset=utf-8")
        val capturedBytes = ByteArray(captureLimit) { 'a'.code.toByte() }

        val known = resolveResponseBody(
            capture = RawResponseBodyCapture(
                bytes = capturedBytes,
                totalBytes = knownBodySize,
                reachedEof = true,
            ),
            contentType = contentType,
            textBodyMaxBytes = captureLimit,
            binaryBodyMaxBytes = captureLimit,
            previewBytes = 16,
            declaredBodySize = knownBodySize,
        )
        val unknownBodySize = captureLimit + 257L
        val unknown = resolveResponseBody(
            capture = RawResponseBodyCapture(
                bytes = capturedBytes,
                totalBytes = unknownBodySize,
                reachedEof = true,
            ),
            contentType = contentType,
            textBodyMaxBytes = captureLimit,
            binaryBodyMaxBytes = captureLimit,
            previewBytes = 16,
            declaredBodySize = null,
        )

        assertEquals(captureLimit, checkNotNull(known.body).length)
        assertEquals(knownBodySize - captureLimit, known.truncatedBytes)
        assertEquals(knownBodySize, known.bodySize)
        assertEquals(captureLimit, checkNotNull(unknown.body).length)
        assertEquals(unknownBodySize - captureLimit, unknown.truncatedBytes)
        assertEquals(unknownBodySize, unknown.bodySize)
    }
}

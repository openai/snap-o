package com.openai.snapo.network.httpurlconnection

import com.openai.snapo.network.capture.RawResponseBodyCapture
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

class SnapOHttpUrlInterceptorTest {

    @Test
    fun `capture defaults preserve full body limits`() {
        val interceptor = SnapOHttpUrlInterceptor()
        try {
            assertEquals(5 * 1024 * 1024, interceptor.textBodyMaxBytes)
            assertEquals(interceptor.textBodyMaxBytes, interceptor.binaryBodyMaxBytes)
        } finally {
            interceptor.close()
        }
    }

    @Test
    fun `inactive interceptor returns the original connection`() {
        val connection = FakeHttpURLConnection()
        val interceptor = SnapOHttpUrlInterceptor()
        try {
            assertSame(connection, interceptor.intercept(connection))
        } finally {
            interceptor.close()
        }
    }

    @Test
    fun `response stream preserves bytes and reports eof once`() {
        val bytes = "response body".encodeToByteArray()
        val captures = mutableListOf<RawResponseBodyCapture>()
        val errors = mutableListOf<Throwable?>()
        val stream = ResponseCapturingInputStream(ByteArrayInputStream(bytes), maxBytes = 4) { capture, error ->
            captures += capture
            errors += error
        }

        assertArrayEquals(bytes, stream.readBytes())
        stream.close()

        assertEquals(1, captures.size)
        assertArrayEquals("resp".encodeToByteArray(), captures.single().bytes)
        assertEquals(bytes.size.toLong(), captures.single().totalBytes)
        assertTrue(captures.single().reachedEof)
        assertNull(errors.single())
    }

    @Test
    fun `closing a partial response does not claim eof`() {
        val captures = mutableListOf<RawResponseBodyCapture>()
        val stream = ResponseCapturingInputStream(
            ByteArrayInputStream("response body".encodeToByteArray()),
            maxBytes = 4,
        ) { capture, _ ->
            captures += capture
        }

        assertEquals('r'.code, stream.read())
        stream.close()
        stream.close()

        assertEquals(1, captures.size)
        assertFalse(captures.single().reachedEof)
        assertEquals(1L, captures.single().totalBytes)
    }

    @Test
    fun `response stream preserves upstream failure`() {
        val expected = IOException("upstream failed")
        var capturedError: Throwable? = null
        val stream = ResponseCapturingInputStream(
            object : InputStream() {
                override fun read(): Int = throw expected
            },
            maxBytes = 4,
        ) { capture, error ->
            assertFalse(capture.reachedEof)
            capturedError = error
        }

        try {
            stream.read()
            fail("Expected the upstream failure")
        } catch (error: IOException) {
            assertSame(expected, error)
        }

        assertSame(expected, capturedError)
    }

    @Test
    fun `response stream reports and preserves upstream close failure`() {
        val expected = IOException("close failed")
        var capturedError: Throwable? = null
        val stream = ResponseCapturingInputStream(
            object : InputStream() {
                override fun read(): Int = -1
                override fun close(): Unit = throw expected
            },
            maxBytes = 4,
        ) { capture, error ->
            assertFalse(capture.reachedEof)
            capturedError = error
        }

        try {
            stream.close()
            fail("Expected the close failure")
        } catch (error: IOException) {
            assertSame(expected, error)
        }

        assertSame(expected, capturedError)
    }

    private class FakeHttpURLConnection : HttpURLConnection(URL("https://example.com")) {
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy(): Boolean = false
    }
}

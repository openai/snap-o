package com.openai.snapo.network.okhttp3

import com.openai.snapo.network.InterceptionDecision
import com.openai.snapo.network.InterceptionHeader
import com.openai.snapo.network.InterceptionResponse
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.BufferedSink
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class SnapOOkHttpInterceptorTest {

    @Test
    fun `capture defaults preserve full body and websocket preview limits`() {
        assertEquals(5 * 1024 * 1024, DefaultTextBodyMaxBytes)
        assertEquals(DefaultTextBodyMaxBytes, DefaultBinaryBodyMaxBytes)
        assertEquals(DefaultTextBodyMaxBytes, DefaultTextPreviewChars)
    }

    @Test
    fun `request capture uses the limit for its encoded representation`() {
        val textRequest = requestWithBody("text/plain".toMediaType())
        val binaryRequest = requestWithBody("application/octet-stream".toMediaType())
        val compressedTextRequest = textRequest.newBuilder()
            .header("Content-Encoding", "gzip")
            .build()

        assertEquals(100, resolveRequestCaptureLimit(textRequest, 100, 20))
        assertEquals(20, resolveRequestCaptureLimit(binaryRequest, 100, 20))
        assertEquals(20, resolveRequestCaptureLimit(compressedTextRequest, 100, 20))
    }

    @Test
    fun `inactive interceptor passes traffic through without serializing the request twice`() {
        val server = MockWebServer()
        val interceptor = SnapOOkHttpInterceptor()
        try {
            server.enqueue(MockResponse.Builder().body("response body").build())
            server.start()
            val requestBody = CountingRequestBody("request body")
            val client = OkHttpClient.Builder()
                .addInterceptor(interceptor)
                .build()
            val request = Request.Builder()
                .url(server.url("/pass-through"))
                .post(requestBody)
                .build()

            client.newCall(request).execute().use { response ->
                assertEquals("response body", response.body.string())
            }

            assertEquals(1, requestBody.writeCount)
        } finally {
            interceptor.close()
            server.close()
        }
    }

    @Test
    fun `inactive websocket factory preserves the delegate socket and listener`() {
        val delegate = RecordingWebSocketFactory()
        val factory = SnapOInterceptorWebSocketFactory(delegate)
        val listener = object : WebSocketListener() {}
        val request = Request.Builder().url("https://example.com/socket").build()
        try {
            val socket = factory.newWebSocket(request, listener)

            assertSame(delegate.socket, socket)
            assertSame(request, delegate.request)
            assertSame(listener, delegate.listener)
        } finally {
            factory.close()
        }
    }

    @Test
    fun `returning upstream unchanged ignores normalized framing and header name order`() {
        val original = originalResponse().copy(
            headerEntries = listOf(
                InterceptionHeader("Content-Type", "text/plain"),
                InterceptionHeader("Set-Cookie", "first=1"),
                InterceptionHeader("Set-Cookie", "second=2"),
                InterceptionHeader("Transfer-Encoding", "chunked"),
                InterceptionHeader("Connection", "keep-alive, Example-Hop"),
                InterceptionHeader("Example-Hop", "temporary"),
            )
        )
        val delivered = original.copy(
            headerEntries = listOf(
                InterceptionHeader("set-cookie", "first=1"),
                InterceptionHeader("set-cookie", "second=2"),
                InterceptionHeader("content-type", "text/plain"),
                InterceptionHeader("Content-Length", "8"),
            )
        )
        val result = fulfill(delivered, original)
        result.response.use {
            assertEquals("unchanged", result.interception?.outcome)
            assertNull(result.interception?.original)
            assertEquals("original", it.body.string())
        }
        assertEquals(false, original.hasSameContent(delivered.copy(headerEntries = delivered.headerEntries.reversed())))
    }

    @Test
    fun `fulfilled routes distinguish mocks from upstream status header or body changes`() {
        val mocked = fulfill(originalResponse())
        mocked.response.close()
        assertEquals("mocked", mocked.interception?.outcome)
        assertNull(mocked.interception?.capture(100, 100)?.originalResponse)

        val original = originalResponse()
        val replacements = listOf(
            original.copy(status = 201),
            original.copy(headerEntries = original.headerEntries + InterceptionHeader("X-Example", "changed")),
            original.copy(body = "edited".encodeUtf8().base64()),
        )
        replacements.forEach { replacement ->
            val result = fulfill(replacement, original)
            result.response.use {
                assertEquals("modified", result.interception?.outcome)
                assertEquals(original, result.interception?.original)
                assertEquals(replacement.status, it.code)
                assertEquals(replacement.body, it.body.byteString().base64())
            }
        }
    }

    @Test
    fun `original capture respects text binary and content encoding settings`() {
        val details = RouteInterception("modified", originalResponse())
        assertNull(details.capture(0, 0).originalResponse?.body)
        assertEquals("original", details.capture(100, 100).originalResponse?.body)

        val binary = details.copy(
            original = originalResponse().copy(
                headerEntries = listOf(InterceptionHeader("Content-Type", "application/octet-stream")),
                body = "AAEC/w==",
            )
        ).capture(100, 100).originalResponse
        assertEquals("AAEC/w==", binary?.body)
        assertEquals("base64", binary?.bodyEncoding)
        val compressed = details.copy(
            original = originalResponse().copy(
                headerEntries = listOf(
                    InterceptionHeader("Content-Type", "application/json"),
                    InterceptionHeader("Content-Encoding", "gzip"),
                ),
                body = "H4sIAAAAAAAA/6uuBQBDv6ajAgAAAA==",
            ),
        )
        val capturedCompressed = compressed.capture(0, 100).originalResponse
        assertEquals(compressed.original?.body, capturedCompressed?.body)
        assertEquals("base64", capturedCompressed?.bodyEncoding)
        assertNull(compressed.capture(100, 0).originalResponse?.body)
        val empty = details.copy(original = originalResponse().copy(status = 204, body = ""))
            .capture(100, 100).originalResponse
        assertEquals(0L, empty?.bodySize)
        assertNull(empty?.body)
    }

    private fun originalResponse() = InterceptionResponse(
        200,
        listOf(InterceptionHeader("Content-Type", "text/plain")),
        "original".encodeUtf8().base64()
    )

    private fun fulfill(response: InterceptionResponse, original: InterceptionResponse? = null): InterceptionResult =
        InterceptionDecision("exchange", "fulfill", "response", response = response).fulfillRoute(
            Request.Builder().url("https://example.test/profile").build(),
            original = original,
        )

    private class CountingRequestBody(private val value: String) : RequestBody() {
        var writeCount: Int = 0
            private set

        override fun contentType(): MediaType? = null

        override fun writeTo(sink: BufferedSink) {
            writeCount += 1
            sink.writeUtf8(value)
        }
    }

    private fun requestWithBody(contentType: MediaType): Request = Request.Builder()
        .url("https://example.com/request")
        .post("body".toRequestBody(contentType))
        .build()

    private class RecordingWebSocketFactory : WebSocket.Factory {
        var request: Request? = null
            private set
        var listener: WebSocketListener? = null
            private set

        val socket = object : WebSocket {
            override fun request(): Request = checkNotNull(request)
            override fun queueSize(): Long = 0L
            override fun send(text: String): Boolean = true
            override fun send(bytes: ByteString): Boolean = true
            override fun close(code: Int, reason: String?): Boolean = true
            override fun cancel() = Unit
        }

        override fun newWebSocket(request: Request, listener: WebSocketListener): WebSocket {
            this.request = request
            this.listener = listener
            return socket
        }
    }
}

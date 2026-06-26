package com.openai.snapo.network.okhttp3

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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class SnapOOkHttpInterceptorTest {

    @Test
    fun `small known bodies can expand the configured capture limit`() {
        assertEquals(7_000_000, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 7_000_000L))
        assertEquals(1_024, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 512L))
        assertEquals(12 * 1024 * 1024, resolveEffectiveMaxBytes(12 * 1024 * 1024, contentLength = null))
        assertEquals(1_024, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 9L * 1024L * 1024L))
        assertEquals(0, resolveEffectiveMaxBytes(-1, contentLength = null))
    }

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

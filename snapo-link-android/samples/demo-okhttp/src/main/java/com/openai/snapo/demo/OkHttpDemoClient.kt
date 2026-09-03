package com.openai.snapo.demo

import android.util.Log
import com.openai.snapo.demo.shared.DemoAction
import com.openai.snapo.demo.shared.DemoClient
import com.openai.snapo.demo.shared.DemoMockServer
import com.openai.snapo.demo.shared.tasks.TasksApi
import com.openai.snapo.demo.shared.toWebSocketUrl
import com.openai.snapo.network.okhttp3.SnapOInterceptorWebSocketFactory
import com.openai.snapo.network.okhttp3.SnapOOkHttpInterceptor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.coroutines.executeAsync
import okio.BufferedSink
import okio.ByteString
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream

internal class OkHttpDemoClient : DemoClient {
    private val mockServer = DemoMockServer()
    private val interceptor = SnapOOkHttpInterceptor()
    private val client = OkHttpClient.Builder().addInterceptor(interceptor).build()
    private val webSocketFactory = SnapOInterceptorWebSocketFactory(client)
    private var activeWebSocket: WebSocket? = null
    override val tasksApi: TasksApi = OkHttpTasksApi(client) {
        withContext(Dispatchers.IO) { mockServer.httpUrl("/api/tasks") }
    }

    override fun handlerFor(action: DemoAction): (suspend () -> Unit)? = when (action) {
        DemoAction.GetRequest -> ::sendGet
        DemoAction.PostRequest -> ::sendPost
        DemoAction.FormPost -> null
        DemoAction.UnknownLengthGzipPost -> ::sendUnknownLengthGzipPost
        DemoAction.NoContentTypeText -> ::sendNoContentTypeText
        DemoAction.Image -> ::sendImage
        DemoAction.CompleteLargeResponse -> suspend { sendLargeResponse(complete = true) }
        DemoAction.TruncatedLargeResponse -> suspend { sendLargeResponse(complete = false) }
        DemoAction.Sse -> ::sendSse
        DemoAction.SlowResponse -> ::sendSlowResponse
        DemoAction.WebSocketEcho -> ::openWebSocket
    }

    override fun close() {
        activeWebSocket?.cancel()
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
        webSocketFactory.close()
        interceptor.close()
        runCatching { mockServer.close() }
            .onFailure { error -> Log.e("SnapODemo", "Failed to stop MockWebServer", error) }
    }

    private suspend fun sendGet() {
        val url = resolveMockHttpUrl("/helloworld.txt") ?: return
        val request = Request.Builder()
            .header("Duplicated", "11111111")
            .addHeader("Duplicated", "2222222")
            .url(url)
            .build()
        executeRequest(request)
    }

    private suspend fun sendPost() {
        val url = resolveMockHttpUrl("/post") ?: return
        val mediaType = "application/json; charset=utf-8".toMediaType()
        val body = """
            {
              "message": "Hello from Snap-O!",
              "source": "okhttp-demo"
            }
        """.trimIndent().toRequestBody(mediaType)
        val request = Request.Builder()
            .url(url)
            .header("X-SnapO-Demo", "okhttp-post")
            .post(body)
            .build()
        executeRequest(request)
    }

    private suspend fun sendUnknownLengthGzipPost() {
        val url = resolveMockHttpUrl("/post-gzip-unknown-length") ?: return
        val payload = """
            {
              "message": "Hello from Snap-O unknown length gzip!",
              "source": "okhttp-demo"
            }
        """.trimIndent()
        val request = Request.Builder()
            .url(url)
            .header("X-SnapO-Demo", "okhttp-post-gzip-unknown-length")
            .header("Content-Encoding", "gzip")
            .post(gzippedUnknownLengthJsonBody(payload))
            .build()
        executeRequest(request)
    }

    private suspend fun sendNoContentTypeText() {
        val url = resolveMockHttpUrl("/no-content-type-text") ?: return
        val request = Request.Builder()
            .url(url)
            .header("X-SnapO-Demo", "okhttp-response-no-content-type-text")
            .build()
        executeRequest(request)
    }

    private suspend fun sendImage() {
        val url = resolveMockHttpUrl("/image.png") ?: return
        val request = Request.Builder()
            .url(url)
            .header("X-SnapO-Demo", "okhttp-image-response")
            .build()
        executeRequest(request, printResponseBody = false)
    }

    private suspend fun sendSlowResponse() {
        val url = resolveMockHttpUrl("/slow-response") ?: return
        val request = Request.Builder()
            .url(url)
            .header("X-SnapO-Demo", "okhttp-slow-body")
            .build()
        executeRequest(request, printResponseBody = false)
    }

    private suspend fun sendSse() {
        val url = resolveMockHttpUrl("/sse") ?: return
        val request = Request.Builder()
            .url(url)
            .header("Accept", "text/event-stream")
            .header("X-SnapO-Demo", "okhttp-sse")
            .build()
        executeRequest(request)
    }

    private suspend fun sendLargeResponse(complete: Boolean) {
        val path = if (complete) "/large-response-complete" else "/large-response-truncated"
        val url = resolveMockHttpUrl(path) ?: return
        val request = Request.Builder()
            .url(url)
            .header("X-SnapO-Demo", "okhttp-large-response")
            .build()
        executeRequest(request, printResponseBody = false)
    }

    private suspend fun executeRequest(request: Request, printResponseBody: Boolean = true) {
        client.newCall(request).executeAsync().use { response ->
            withContext(Dispatchers.IO) {
                if (printResponseBody) {
                    println(response.body.string())
                } else {
                    response.body.bytes()
                }
            }
        }
    }

    private suspend fun openWebSocket() {
        val httpUrl = resolveMockHttpUrl("/ws-echo") ?: return
        val request = Request.Builder()
            .url(httpUrl.toWebSocketUrl())
            .build()

        activeWebSocket?.cancel()
        activeWebSocket = webSocketFactory.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    webSocket.send("Hello from Snap-O demo!")
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    webSocket.close(1000, "Closing after echo")
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    webSocket.close(1000, "Closing after echo")
                }
            }
        )
    }

    private suspend fun resolveMockHttpUrl(path: String): String? {
        return withContext(Dispatchers.IO) {
            runCatching { mockServer.httpUrl(path) }
                .onFailure { error -> Log.e("SnapODemo", "Failed to resolve MockWebServer URL", error) }
                .getOrNull()
        }
    }
}

private fun gzippedUnknownLengthJsonBody(text: String): RequestBody {
    val gzipped = gzip(text.toByteArray(Charsets.UTF_8))
    return object : RequestBody() {
        override fun contentType() = "application/json; charset=utf-8".toMediaType()

        override fun contentLength(): Long = -1L

        override fun writeTo(sink: BufferedSink) {
            sink.write(gzipped)
        }
    }
}

private fun gzip(bytes: ByteArray): ByteArray {
    val output = ByteArrayOutputStream()
    GZIPOutputStream(output).use { it.write(bytes) }
    return output.toByteArray()
}

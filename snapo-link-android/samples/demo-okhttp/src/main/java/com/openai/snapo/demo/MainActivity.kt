package com.openai.snapo.demo

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.openai.snapo.network.okhttp3.SnapOOkHttpInterceptor
import com.openai.snapo.network.okhttp3.withSnapOInterceptor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
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
import java.io.IOException
import java.net.InetAddress
import java.util.zip.GZIPOutputStream

class MainActivity : ComponentActivity() {

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .addInterceptor(SnapOOkHttpInterceptor())
            .build()
    }
    private val webSocketFactory = client.withSnapOInterceptor()

    private var activeWebSocket: WebSocket? = null
    private var mockServer: MockWebServer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch(Dispatchers.IO) {
            ensureMockServer()
        }
        enableEdgeToEdge()
        setContent {
            MaterialTheme {
                val scope = rememberCoroutineScope()
                Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
                    Greeting(
                        onNetworkRequestClick = { runGetRequest(scope) },
                        onPostRequestClick = { runPostRequest(scope) },
                        onUnknownLengthGzipPostRequestClick = { runUnknownLengthGzipPostRequest(scope) },
                        onNoContentTypeTextResponseClick = { runNoContentTypeTextResponseRequest(scope) },
                        onWebSocketDemoClick = { startWebSocketDemo() },
                        modifier = Modifier.padding(innerPadding)
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        activeWebSocket?.close(1000, "Activity destroyed")
        runCatching { mockServer?.close() }
            .onFailure { error -> Log.e("SnapODemo", "Failed to stop MockWebServer", error) }
        mockServer = null
        super.onDestroy()
    }

    private fun runGetRequest(scope: CoroutineScope) {
        val request = Request.Builder()
            .header("Duplicated", "11111111")
            .addHeader("Duplicated", "2222222")
            .url("https://publicobject.com/helloworld.txt")
            .build()
        executeRequest(scope, request)
    }

    private fun runPostRequest(scope: CoroutineScope) {
        val mediaType = "application/json; charset=utf-8".toMediaType()
        val body = """
            {
              "message": "Hello from Snap-O!",
              "source": "okhttp-demo"
            }
        """.trimIndent().toRequestBody(mediaType)
        val request = Request.Builder()
            .url("https://postman-echo.com/post")
            .header("X-SnapO-Demo", "okhttp-post")
            .post(body)
            .build()
        executeRequest(scope, request)
    }

    private fun runUnknownLengthGzipPostRequest(scope: CoroutineScope) {
        val payload = """
            {
              "message": "Hello from Snap-O unknown length gzip!",
              "source": "okhttp-demo"
            }
        """.trimIndent()
        val request = Request.Builder()
            .url("https://postman-echo.com/post")
            .header("X-SnapO-Demo", "okhttp-post-gzip-unknown-length")
            .header("Content-Encoding", "gzip")
            .post(gzippedUnknownLengthJsonBody(payload))
            .build()
        executeRequest(scope, request)
    }

    private fun runNoContentTypeTextResponseRequest(scope: CoroutineScope) {
        scope.launch {
            val url = withContext(Dispatchers.IO) {
                val server = ensureMockServer() ?: return@withContext null
                "http://127.0.0.1:${server.port}/no-content-type-text"
            }
            if (url == null) {
                Log.e("SnapODemo", "MockWebServer is not running")
                return@launch
            }
            val request = Request.Builder()
                .url(url)
                .header("X-SnapO-Demo", "okhttp-response-no-content-type-text")
                .build()
            executeRequest(scope, request)
        }
    }

    private fun executeRequest(scope: CoroutineScope, request: Request) {
        val call = client.newCall(request)
        scope.launch {
            try {
                call.executeAsync().use { response ->
                    withContext(Dispatchers.IO) {
                        println(response.body.string())
                    }
                }
            } catch (error: IOException) {
                Log.e("SnapODemo", "Request failed: ${request.url}", error)
            }
        }
    }

    private fun startWebSocketDemo() {
        val request = Request.Builder()
            .url("wss://echo.websocket.org")
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

    private fun ensureMockServer(): MockWebServer? {
        mockServer?.let { return it }
        val started = runCatching {
            createDemoMockServer().also {
                it.start(InetAddress.getByName("127.0.0.1"), 0)
                Log.d("SnapODemo", "MockWebServer started on 127.0.0.1:${it.port}")
            }
        }.onFailure { error ->
            Log.e("SnapODemo", "Failed to start MockWebServer", error)
        }.getOrNull()
        if (started != null) {
            mockServer = started
        }
        return started
    }
}

private fun createDemoMockServer(): MockWebServer {
    val body = """{"message":"Hello from Snap-O without Content-Type","source":"okhttp-demo"}"""
    return MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                Log.d("SnapODemo", "MockWebServer dispatch target=${request.target}")
                return when (request.target.substringBefore('?')) {
                    "/no-content-type-text" -> MockResponse.Builder()
                        .code(200)
                        .setHeader("Content-Length", body.toByteArray(Charsets.UTF_8).size.toString())
                        .setHeader("Connection", "close")
                        .body(body)
                        .build()
                    else -> MockResponse.Builder().code(404).build()
                }
            }
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

@Composable
fun Greeting(
    onNetworkRequestClick: () -> Unit,
    onPostRequestClick: () -> Unit,
    onUnknownLengthGzipPostRequestClick: () -> Unit,
    onNoContentTypeTextResponseClick: () -> Unit,
    onWebSocketDemoClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = modifier.padding(16.dp),
    ) {
        Button(onClick = onNetworkRequestClick) {
            Text("Network Request")
        }
        Button(onClick = onPostRequestClick) {
            Text("POST Request")
        }
        Button(onClick = onUnknownLengthGzipPostRequestClick) {
            Text("POST gzip (unknown length)")
        }
        Button(onClick = onNoContentTypeTextResponseClick) {
            Text("GET text (no Content-Type)")
        }
        Button(onClick = onWebSocketDemoClick) {
            Text("WebSocket Echo")
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun GreetingPreview() {
    MaterialTheme {
        Greeting(
            onNetworkRequestClick = {},
            onPostRequestClick = {},
            onUnknownLengthGzipPostRequestClick = {},
            onNoContentTypeTextResponseClick = {},
            onWebSocketDemoClick = {},
        )
    }
}

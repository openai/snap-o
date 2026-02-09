package com.openai.snapo.demo.ktor

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
import com.openai.snapo.demo.shared.DemoMockServer
import com.openai.snapo.demo.shared.toWebSocketUrl
import com.openai.snapo.network.okhttp3.SnapOOkHttpInterceptor
import com.openai.snapo.network.okhttp3.withSnapOInterceptor
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.forms.formData
import io.ktor.client.request.forms.submitFormWithBinaryData
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.send
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

class MainActivity : ComponentActivity() {

    private val mockServer = DemoMockServer()

    private val httpClient: HttpClient by lazy {
        val okHttpClient = OkHttpClient.Builder()
            .addInterceptor(SnapOOkHttpInterceptor())
            .build()

        HttpClient(OkHttp) {
            engine {
                preconfigured = okHttpClient
                webSocketFactory = okHttpClient.withSnapOInterceptor()
            }
            install(WebSockets)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch(Dispatchers.IO) {
            runCatching { mockServer.ensureStarted() }
                .onFailure { error -> Log.e(DemoLogTag, "Failed to start MockWebServer", error) }
        }
        enableEdgeToEdge()
        setContent {
            DemoScreen(
                httpClient = httpClient,
                mockServer = mockServer,
            )
        }
    }

    override fun onDestroy() {
        httpClient.close()
        runCatching { mockServer.close() }
            .onFailure { error -> Log.e(DemoLogTag, "Failed to stop MockWebServer", error) }
        super.onDestroy()
    }
}

@Composable
private fun DemoScreen(httpClient: HttpClient, mockServer: DemoMockServer) {
    MaterialTheme {
        val scope = rememberCoroutineScope()
        Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
            DemoContent(
                onNetworkRequestClick = {
                    scope.launch { performGetRequest(httpClient, mockServer) }
                },
                onPostRequestClick = {
                    scope.launch { performPostRequest(httpClient, mockServer) }
                },
                onFormRequestClick = {
                    scope.launch { performFormRequest(httpClient, mockServer) }
                },
                onWebSocketDemoClick = {
                    scope.launch { performWebSocketDemo(httpClient, mockServer) }
                },
                modifier = Modifier.padding(innerPadding),
            )
        }
    }
}

private suspend fun performGetRequest(httpClient: HttpClient, mockServer: DemoMockServer) {
    val url = resolveMockHttpUrl(mockServer, "/helloworld.txt") ?: return
    httpClient.get(url) {
        headers {
            append("Duplicated", "1111111")
            append("Duplicated", "2222222")
        }
    }
}

private suspend fun performPostRequest(httpClient: HttpClient, mockServer: DemoMockServer) {
    val url = resolveMockHttpUrl(mockServer, "/post") ?: return
    httpClient.post(url) {
        contentType(ContentType.Application.Json)
        headers { append("X-SnapO-Demo", "ktor-post") }
        setBody(
            """
            {
              "message": "Hello from Snap-O!",
              "source": "ktor-okhttp-demo"
            }
            """.trimIndent()
        )
    }
}

private suspend fun performFormRequest(httpClient: HttpClient, mockServer: DemoMockServer) {
    val url = resolveMockHttpUrl(mockServer, "/form-post") ?: return
    httpClient.submitFormWithBinaryData(
        url = url,
        formData = formData {
            append("field1", "example payload")
            append("field2", """{"test":true,"value":123}""")
        },
    )
}

private suspend fun performWebSocketDemo(httpClient: HttpClient, mockServer: DemoMockServer) {
    val websocketUrl = resolveMockHttpUrl(mockServer, "/ws-echo")?.toWebSocketUrl() ?: return
    httpClient.webSocket(urlString = websocketUrl) {
        send("Hello from Snap-O!")
        for (frame in incoming) {
            if (frame is Frame.Text) {
                close(
                    CloseReason(
                        CloseReason.Codes.NORMAL,
                        "Closing after echo",
                    )
                )
                break
            }
        }
    }
}

private suspend fun resolveMockHttpUrl(mockServer: DemoMockServer, path: String): String? {
    return withContext(Dispatchers.IO) {
        runCatching { mockServer.httpUrl(path) }
            .onFailure { error -> Log.e(DemoLogTag, "Failed to resolve MockWebServer URL", error) }
            .getOrNull()
    }
}

@Composable
private fun DemoContent(
    onNetworkRequestClick: () -> Unit,
    onPostRequestClick: () -> Unit,
    onFormRequestClick: () -> Unit,
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
        Button(onClick = onFormRequestClick) {
            Text("Form POST")
        }
        Button(onClick = onWebSocketDemoClick) {
            Text("WebSocket Echo")
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun DemoPreview() {
    MaterialTheme {
        DemoContent(
            onNetworkRequestClick = {},
            onPostRequestClick = {},
            onFormRequestClick = {},
            onWebSocketDemoClick = {},
        )
    }
}

private const val DemoLogTag = "SnapODemo"

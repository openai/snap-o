package com.openai.snapo.demo.ktor

import android.os.Bundle
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
import io.ktor.http.HttpMethod
import io.ktor.http.contentType
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.send
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

class MainActivity : ComponentActivity() {

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
        enableEdgeToEdge()
        setContent { DemoScreen(httpClient = httpClient) }
    }

    override fun onDestroy() {
        httpClient.close()
        super.onDestroy()
    }
}

@Composable
private fun DemoScreen(httpClient: HttpClient) {
    MaterialTheme {
        val scope = rememberCoroutineScope()
        Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
            DemoContent(
                onNetworkRequestClick = {
                    scope.launch { performGetRequest(httpClient) }
                },
                onPostRequestClick = {
                    scope.launch { performPostRequest(httpClient) }
                },
                onFormRequestClick = {
                    scope.launch { performFormRequest(httpClient) }
                },
                onWebSocketDemoClick = {
                    scope.launch { performWebSocketDemo(httpClient) }
                },
                modifier = Modifier.padding(innerPadding),
            )
        }
    }
}

private suspend fun performGetRequest(httpClient: HttpClient) {
    httpClient.get("https://publicobject.com/helloworld.txt") {
        headers {
            append("Duplicated", "1111111")
            append("Duplicated", "2222222")
        }
    }
}

private suspend fun performPostRequest(httpClient: HttpClient) {
    httpClient.post("https://postman-echo.com/post") {
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

private suspend fun performFormRequest(httpClient: HttpClient) {
    httpClient.submitFormWithBinaryData(
        url = "https://postman-echo.com/post",
        formData = formData {
            append("field1", "example payload")
            append("field2", """{"test":true,"value":123}""")
        },
    ) {
        method = HttpMethod.Post
        url { parameters.append("param1", "example") }
    }
}

private suspend fun performWebSocketDemo(httpClient: HttpClient) {
    httpClient.webSocket(urlString = "wss://echo.websocket.org") {
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

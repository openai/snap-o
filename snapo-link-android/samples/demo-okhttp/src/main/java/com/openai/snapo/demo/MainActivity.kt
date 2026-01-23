package com.openai.snapo.demo

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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.coroutines.executeAsync
import okio.ByteString

class MainActivity : ComponentActivity() {

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .addInterceptor(SnapOOkHttpInterceptor())
            .build()
    }
    private val webSocketFactory = client.withSnapOInterceptor()

    private var activeWebSocket: WebSocket? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme {
                val scope = rememberCoroutineScope()
                Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
                    Greeting(
                        onNetworkRequestClick = {
                            val request = Request.Builder()
                                .header("Duplicated", "11111111")
                                .addHeader("Duplicated", "2222222")
                                .url("https://publicobject.com/helloworld.txt")
                                .build()
                            val call = client.newCall(request)
                            scope.launch {
                                call.executeAsync().use { response ->
                                    withContext(Dispatchers.IO) {
                                        println(response.body.string())
                                    }
                                }
                            }
                        },
                        onPostRequestClick = {
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
                            val call = client.newCall(request)
                            scope.launch {
                                call.executeAsync().use { response ->
                                    withContext(Dispatchers.IO) {
                                        println(response.body.string())
                                    }
                                }
                            }
                        },
                        onWebSocketDemoClick = { startWebSocketDemo() },
                        modifier = Modifier.padding(innerPadding)
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        activeWebSocket?.close(1000, "Activity destroyed")
        super.onDestroy()
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
}

@Composable
fun Greeting(
    onNetworkRequestClick: () -> Unit,
    onPostRequestClick: () -> Unit,
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
            onWebSocketDemoClick = {},
        )
    }
}

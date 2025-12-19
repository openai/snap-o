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
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.openai.snapo.demo.ktor.ui.theme.SnapOLinkTheme
import com.openai.snapo.network.okhttp3.SnapOOkHttpInterceptor
import com.openai.snapo.network.okhttp3.withSnapOInterceptor
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.get
import io.ktor.client.request.headers
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
        setContent {
            SnapOLinkTheme {
                val scope = rememberCoroutineScope()
                Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
                    DemoContent(
                        onNetworkRequestClick = {
                            scope.launch {
                                httpClient.get("https://publicobject.com/helloworld.txt") {
                                    headers {
                                        append("Duplicated", "1111111")
                                        append("Duplicated", "2222222")
                                    }
                                }
                            }
                        },
                        onWebSocketDemoClick = {
                            scope.launch {
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
                        },
                        modifier = Modifier.padding(innerPadding),
                    )
                }
            }
        }
    }

    override fun onDestroy() {
        httpClient.close()
        super.onDestroy()
    }
}

@Composable
private fun DemoContent(
    onNetworkRequestClick: () -> Unit,
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
        Button(onClick = onWebSocketDemoClick) {
            Text("WebSocket Echo")
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun DemoPreview() {
    SnapOLinkTheme {
        DemoContent(
            onNetworkRequestClick = {},
            onWebSocketDemoClick = {},
        )
    }
}

package com.openai.snapo.demo

import android.os.Bundle
import android.os.SystemClock
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.openai.snapo.demo.ui.theme.SnapOLinkTheme
import com.openai.snapo.link.core.Header
import com.openai.snapo.link.core.RequestWillBeSent
import com.openai.snapo.link.core.ResponseReceived
import com.openai.snapo.link.core.SnapOLink
import com.openai.snapo.link.okhttp3.SnapOOkHttpInterceptor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.coroutines.executeAsync

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val client = OkHttpClient.Builder()
            .addInterceptor(SnapOOkHttpInterceptor())
            .build()
        enableEdgeToEdge()
        setContent {
            SnapOLinkTheme {
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
                        modifier = Modifier.padding(innerPadding)
                    )
                }
            }
        }
    }
}

@Composable
fun Greeting(onNetworkRequestClick: () -> Unit, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    Column(
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = modifier.padding(16.dp),
    ) {
        var nextId by remember { mutableIntStateOf(0) }
        var isSent by remember { mutableStateOf(false) }
        Button(
            onClick = {
                scope.launch {
                    SnapOLink.serverOrNull()?.publish(
                        RequestWillBeSent(
                            id = "$nextId",
                            tWallMs = System.currentTimeMillis(),
                            tMonoNs = SystemClock.elapsedRealtimeNanos(),
                            method = "GET",
                            url = "https://example.com",
                            headers = listOf(Header("User-Agent", "SnapO Demo")),
                        )
                    )
                    isSent = true
                }
            },
            enabled = !isSent,
        ) {
            Text("Begin Request")
        }
        Button(
            onClick = {
                scope.launch {
                    SnapOLink.serverOrNull()?.publish(
                        ResponseReceived(
                            id = "$nextId",
                            tWallMs = System.currentTimeMillis(),
                            tMonoNs = SystemClock.elapsedRealtimeNanos(),
                            code = 200,
                        )
                    )
                    isSent = false
                    nextId++
                }
            },
            enabled = isSent,
        ) {
            Text("End Request")
        }
        Button(onClick = onNetworkRequestClick) {
            Text("Network Request")
        }
    }
}

@Preview(showBackground = true)
@Composable
fun GreetingPreview() {
    SnapOLinkTheme {
        Greeting(onNetworkRequestClick = {})
    }
}

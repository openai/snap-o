package com.openai.snapo.demo.httpurlconnection

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
import com.openai.snapo.network.httpurlconnection.SnapOHttpUrlInterceptor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL

class MainActivity : ComponentActivity() {

    private val interceptor = SnapOHttpUrlInterceptor()
    private val mockServer = DemoMockServer()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lifecycleScope.launch(Dispatchers.IO) {
            runCatching { mockServer.ensureStarted() }
                .onFailure { error -> Log.e(DemoLogTag, "Failed to start MockWebServer", error) }
        }
        enableEdgeToEdge()
        setContent {
            DemoScreen(
                interceptor = interceptor,
                mockServer = mockServer,
            )
        }
    }

    override fun onDestroy() {
        interceptor.close()
        runCatching { mockServer.close() }
            .onFailure { error -> Log.e(DemoLogTag, "Failed to stop MockWebServer", error) }
        super.onDestroy()
    }
}

@Composable
private fun DemoScreen(interceptor: SnapOHttpUrlInterceptor, mockServer: DemoMockServer) {
    MaterialTheme {
        val scope = rememberCoroutineScope()
        Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
            DemoContent(
                onNetworkRequestClick = {
                    scope.launch { performGetRequest(interceptor, mockServer) }
                },
                onPostRequestClick = {
                    scope.launch { performPostRequest(interceptor, mockServer) }
                },
                modifier = Modifier.padding(innerPadding),
            )
        }
    }
}

private suspend fun performGetRequest(
    interceptor: SnapOHttpUrlInterceptor,
    mockServer: DemoMockServer,
) {
    val url = resolveMockHttpUrl(mockServer, "/helloworld.txt") ?: return
    withContext(Dispatchers.IO) {
        val connection = interceptor.open(
            URL(url)
        )
        try {
            connection.requestMethod = "GET"
            connection.addRequestProperty("Duplicated", "11111111")
            connection.addRequestProperty("Duplicated", "2222222")
            connection.connect()
            connection.inputStream.bufferedReader().use { reader ->
                println(reader.readText())
            }
        } finally {
            connection.disconnect()
        }
    }
}

private suspend fun performPostRequest(
    interceptor: SnapOHttpUrlInterceptor,
    mockServer: DemoMockServer,
) {
    val url = resolveMockHttpUrl(mockServer, "/post") ?: return
    withContext(Dispatchers.IO) {
        val connection = interceptor.open(
            URL(url)
        )
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty(
                "Content-Type",
                "application/json; charset=utf-8",
            )
            connection.setRequestProperty("X-SnapO-Demo", "httpurl-post")
            val payload = """
                {
                  "message": "Hello from Snap-O!",
                  "source": "httpurlconnection-demo"
                }
            """.trimIndent()
            connection.outputStream.use { output ->
                output.write(payload.toByteArray(Charsets.UTF_8))
            }
            val stream = if (connection.responseCode >= 400) {
                connection.errorStream
            } else {
                connection.inputStream
            }
            stream?.bufferedReader()?.use { reader ->
                println(reader.readText())
            }
        } finally {
            connection.disconnect()
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
    }
}

@Preview(showBackground = true)
@Composable
private fun DemoPreview() {
    MaterialTheme {
        DemoContent(
            onNetworkRequestClick = {},
            onPostRequestClick = {},
        )
    }
}

private const val DemoLogTag = "SnapODemo"

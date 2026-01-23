package com.openai.snapo.demo.httpurlconnection

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
import com.openai.snapo.network.httpurlconnection.SnapOHttpUrlInterceptor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URL

class MainActivity : ComponentActivity() {

    private val interceptor = SnapOHttpUrlInterceptor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { DemoScreen(interceptor = interceptor) }
    }

    override fun onDestroy() {
        interceptor.close()
        super.onDestroy()
    }
}

@Composable
private fun DemoScreen(interceptor: SnapOHttpUrlInterceptor) {
    MaterialTheme {
        val scope = rememberCoroutineScope()
        Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
            DemoContent(
                onNetworkRequestClick = {
                    scope.launch { performGetRequest(interceptor) }
                },
                onPostRequestClick = {
                    scope.launch { performPostRequest(interceptor) }
                },
                modifier = Modifier.padding(innerPadding),
            )
        }
    }
}

private suspend fun performGetRequest(interceptor: SnapOHttpUrlInterceptor) {
    withContext(Dispatchers.IO) {
        val connection = interceptor.open(
            URL("https://publicobject.com/helloworld.txt")
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

private suspend fun performPostRequest(interceptor: SnapOHttpUrlInterceptor) {
    withContext(Dispatchers.IO) {
        val connection = interceptor.open(
            URL("https://postman-echo.com/post")
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

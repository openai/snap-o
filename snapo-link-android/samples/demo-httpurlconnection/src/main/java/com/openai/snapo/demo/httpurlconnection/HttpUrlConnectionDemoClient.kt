package com.openai.snapo.demo.httpurlconnection

import android.util.Log
import com.openai.snapo.demo.shared.DemoAction
import com.openai.snapo.demo.shared.DemoClient
import com.openai.snapo.demo.shared.DemoMockServer
import com.openai.snapo.demo.shared.tasks.TasksApi
import com.openai.snapo.network.httpurlconnection.SnapOHttpUrlInterceptor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URL

internal class HttpUrlConnectionDemoClient : DemoClient {
    private val mockServer = DemoMockServer()
    private val interceptor = SnapOHttpUrlInterceptor()
    override val tasksApi: TasksApi = HttpUrlConnectionTasksApi(interceptor::open) {
        withContext(Dispatchers.IO) { mockServer.httpUrl("/api/tasks") }
    }

    override fun handlerFor(action: DemoAction): (suspend () -> Unit)? = when (action) {
        DemoAction.GetRequest -> ::sendGet
        DemoAction.PostRequest -> ::sendPost
        DemoAction.FormPost,
        DemoAction.UnknownLengthGzipPost,
        DemoAction.NoContentTypeText,
        DemoAction.Image,
        DemoAction.CompleteLargeResponse,
        DemoAction.TruncatedLargeResponse,
        DemoAction.Sse,
        DemoAction.SlowResponse,
        DemoAction.WebSocketEcho -> null
    }

    override fun close() {
        interceptor.close()
        runCatching { mockServer.close() }
            .onFailure { error -> Log.e(DemoLogTag, "Failed to stop MockWebServer", error) }
    }

    private suspend fun sendGet() {
        val url = resolveMockHttpUrl("/helloworld.txt") ?: return
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

    private suspend fun sendPost() {
        val url = resolveMockHttpUrl("/post") ?: return
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

    private suspend fun resolveMockHttpUrl(path: String): String? {
        return withContext(Dispatchers.IO) {
            runCatching { mockServer.httpUrl(path) }
                .onFailure { error -> Log.e(DemoLogTag, "Failed to resolve MockWebServer URL", error) }
                .getOrNull()
        }
    }
}

private const val DemoLogTag = "SnapODemo"

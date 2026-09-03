package com.openai.snapo.demo.ktor

import android.util.Log
import com.openai.snapo.demo.shared.DemoAction
import com.openai.snapo.demo.shared.DemoClient
import com.openai.snapo.demo.shared.DemoMockServer
import com.openai.snapo.demo.shared.tasks.TasksApi
import com.openai.snapo.demo.shared.toWebSocketUrl
import com.openai.snapo.network.okhttp3.SnapOInterceptorWebSocketFactory
import com.openai.snapo.network.okhttp3.SnapOOkHttpInterceptor
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
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
import io.ktor.serialization.kotlinx.json.json
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.send
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient

internal class KtorDemoClient : DemoClient {
    private val mockServer = DemoMockServer()
    private val interceptor = SnapOOkHttpInterceptor()
    private val okHttpClient = OkHttpClient.Builder().addInterceptor(interceptor).build()
    private val webSockets = SnapOInterceptorWebSocketFactory(okHttpClient)
    private val httpClient = HttpClient(OkHttp) {
        engine {
            preconfigured = okHttpClient
            webSocketFactory = webSockets
        }
        install(WebSockets)
        install(ContentNegotiation) {
            json(Json { ignoreUnknownKeys = true })
        }
    }
    override val tasksApi: TasksApi = KtorTasksApi(httpClient) {
        withContext(Dispatchers.IO) { mockServer.httpUrl("/api/tasks") }
    }

    override fun handlerFor(action: DemoAction): (suspend () -> Unit)? = when (action) {
        DemoAction.GetRequest -> ::sendGet
        DemoAction.PostRequest -> ::sendPost
        DemoAction.FormPost -> ::sendForm
        DemoAction.WebSocketEcho -> ::openWebSocket
        DemoAction.UnknownLengthGzipPost,
        DemoAction.NoContentTypeText,
        DemoAction.Image,
        DemoAction.CompleteLargeResponse,
        DemoAction.TruncatedLargeResponse,
        DemoAction.Sse,
        DemoAction.SlowResponse -> null
    }

    override fun close() {
        httpClient.close()
        okHttpClient.dispatcher.cancelAll()
        okHttpClient.connectionPool.evictAll()
        okHttpClient.dispatcher.executorService.shutdown()
        webSockets.close()
        interceptor.close()
        runCatching { mockServer.close() }
            .onFailure { error -> Log.e(DemoLogTag, "Failed to stop MockWebServer", error) }
    }

    private suspend fun sendGet() {
        val url = resolveMockHttpUrl("/helloworld.txt") ?: return
        httpClient.get(url) {
            headers {
                append("Duplicated", "1111111")
                append("Duplicated", "2222222")
            }
        }
    }

    private suspend fun sendPost() {
        val url = resolveMockHttpUrl("/post") ?: return
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

    private suspend fun sendForm() {
        val url = resolveMockHttpUrl("/form-post") ?: return
        httpClient.submitFormWithBinaryData(
            url = url,
            formData = formData {
                append("field1", "example payload")
                append("field2", """{"test":true,"value":123}""")
            },
        )
    }

    private suspend fun openWebSocket() {
        val websocketUrl = resolveMockHttpUrl("/ws-echo")?.toWebSocketUrl() ?: return
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

    private suspend fun resolveMockHttpUrl(path: String): String? {
        return withContext(Dispatchers.IO) {
            runCatching { mockServer.httpUrl(path) }
                .onFailure { error -> Log.e(DemoLogTag, "Failed to resolve MockWebServer URL", error) }
                .getOrNull()
        }
    }
}

private const val DemoLogTag = "SnapODemo"

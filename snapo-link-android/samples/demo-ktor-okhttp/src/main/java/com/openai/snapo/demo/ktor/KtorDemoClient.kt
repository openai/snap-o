package com.openai.snapo.demo.ktor

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
        mockServer.resolveUrl("/api/tasks")
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
        mockServer.close()
    }

    private suspend fun sendGet() {
        val url = mockServer.resolveUrl("/helloworld.txt")
        httpClient.get(url) {
            headers {
                append("Duplicated", "1111111")
                append("Duplicated", "2222222")
            }
        }
    }

    private suspend fun sendPost() {
        val url = mockServer.resolveUrl("/post")
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
        val url = mockServer.resolveUrl("/form-post")
        httpClient.submitFormWithBinaryData(
            url = url,
            formData = formData {
                append("field1", "example payload")
                append("field2", """{"test":true,"value":123}""")
            },
        )
    }

    private suspend fun openWebSocket() {
        val websocketUrl = mockServer.resolveUrl("/ws-echo").toWebSocketUrl()
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
}

package com.openai.snapo.demo.shared

import android.util.Log
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.decodeBase64
import java.net.InetAddress
import java.util.concurrent.TimeUnit

class DemoMockServer {
    private var server: MockWebServer? = null

    fun ensureStarted() {
        if (server != null) return
        server = createServer().also { started ->
            started.start(InetAddress.getByName(MockHost), 0)
            Log.d(DemoLogTag, "MockWebServer started on $MockHost:${started.port}")
        }
    }

    fun httpUrl(path: String): String {
        ensureStarted()
        val port = checkNotNull(server).port
        return "http://$MockHost:$port$path"
    }

    fun close() {
        server?.close()
        server = null
    }
}

private fun createServer(): MockWebServer {
    val plainTextBody = "Hello from Snap-O MockWebServer!\n"
    val postBody = """{"ok":true,"endpoint":"post","source":"mockwebserver"}"""
    val gzipPostBody = """{"ok":true,"endpoint":"post-gzip-unknown-length","source":"mockwebserver"}"""
    val noTypeBody = """{"message":"Hello from Snap-O without Content-Type","source":"okhttp-demo"}"""
    val imageBody = checkNotNull(DemoAppIconPng.decodeBase64())
    val formBody = """{"ok":true,"endpoint":"form-post","source":"mockwebserver"}"""
    val slowBody = """{"message":"${"x".repeat(SlowBodyPayloadCharacters)}","source":"okhttp-demo"}"""
    return MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                Log.d(DemoLogTag, "MockWebServer dispatch target=${request.target}")
                return when (request.target.substringBefore('?')) {
                    "/helloworld.txt" -> MockResponse.Builder()
                        .code(200)
                        .setHeader("Content-Type", "text/plain; charset=utf-8")
                        .setHeader("Content-Length", plainTextBody.toByteArray(Charsets.UTF_8).size.toString())
                        .setHeader("Connection", "close")
                        .body(plainTextBody)
                        .build()
                    "/post" -> MockResponse.Builder()
                        .code(200)
                        .setHeader("Content-Type", "application/json; charset=utf-8")
                        .setHeader("Content-Length", postBody.toByteArray(Charsets.UTF_8).size.toString())
                        .setHeader("Connection", "close")
                        .body(postBody)
                        .build()
                    "/post-gzip-unknown-length" -> MockResponse.Builder()
                        .code(200)
                        .setHeader("Content-Type", "application/json; charset=utf-8")
                        .setHeader("Content-Length", gzipPostBody.toByteArray(Charsets.UTF_8).size.toString())
                        .setHeader("Connection", "close")
                        .body(gzipPostBody)
                        .build()
                    "/form-post" -> MockResponse.Builder()
                        .code(200)
                        .setHeader("Content-Type", "application/json; charset=utf-8")
                        .setHeader("Content-Length", formBody.toByteArray(Charsets.UTF_8).size.toString())
                        .setHeader("Connection", "close")
                        .body(formBody)
                        .build()
                    "/no-content-type-text" -> MockResponse.Builder()
                        .code(200)
                        .setHeader("Content-Length", noTypeBody.toByteArray(Charsets.UTF_8).size.toString())
                        .setHeader("Connection", "close")
                        .body(noTypeBody)
                        .build()
                    "/image.png" -> imageResponse(imageBody)
                    "/slow-response" -> slowResponse(slowBody)
                    "/ws-echo" -> MockResponse.Builder()
                        .webSocketUpgrade(
                            object : WebSocketListener() {
                                override fun onMessage(webSocket: WebSocket, text: String) {
                                    webSocket.send(text)
                                    webSocket.close(1000, "Echo complete")
                                }

                                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                                    webSocket.send(bytes)
                                    webSocket.close(1000, "Echo complete")
                                }
                            }
                        )
                        .build()
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
    }
}

private fun imageResponse(body: ByteString): MockResponse = MockResponse.Builder()
    .code(200)
    .setHeader("Content-Type", "image/png")
    .setHeader("Connection", "close")
    .body(Buffer().write(body))
    .build()

private fun slowResponse(body: String): MockResponse = MockResponse.Builder()
    .code(200)
    .setHeader("Content-Type", "application/json; charset=utf-8")
    .setHeader("X-SnapO-Demo", "headers-before-body")
    .setHeader("Connection", "close")
    .body(body)
    .bodyDelay(SlowBodyInitialDelayMs, TimeUnit.MILLISECONDS)
    .throttleBody(
        bytesPerPeriod = SlowBodyChunkBytes,
        period = SlowBodyChunkDelayMs,
        unit = TimeUnit.MILLISECONDS,
    )
    .build()

fun String.toWebSocketUrl(): String {
    return when {
        startsWith("http://") -> "ws://${removePrefix("http://")}"
        startsWith("https://") -> "wss://${removePrefix("https://")}"
        else -> this
    }
}

private const val DemoLogTag: String = "SnapODemo"
private const val MockHost: String = "127.0.0.1"
private const val SlowBodyPayloadCharacters: Int = 1024 * 1024
private const val SlowBodyInitialDelayMs: Long = 2_000L
private const val SlowBodyChunkBytes: Long = 128L * 1024L
private const val SlowBodyChunkDelayMs: Long = 250L

private val DemoAppIconPng: String = """
    iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAMAAAD04JH5AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAHsUExURUdwTJDci5/jm1vOVDnJMTfHLjvI
    M6zyp0nPQH3idz/MNzvKMj7MNjjIL0HNOJ/umqTvn3nfclPTTDjJMLj2tHffcT3LNTzJM3nfc3TcboTjfoPjfkjPQF7WVnvidYLkfIflg7j3tXrfdJfqknTc
    bXDca5frkrr4t6fxo6fwoyO1GyS0HCS0GSa1GyW2GyO1Gf///yGzGSG0GiCyFyCxFyG2Gx2wFUXGPfn/9/b+9Su8IvP+8v7//bzoufH88Mzvyfr/+q/krByu
    FMDpvfb/9bfnteP44W/aaSq7Iim4Ief/5Nn/1u797sjuxjTELLTksTPFK83xy8DsvnPPbbvruMTtwcTrw+T641vFVZfek9Pz0eL/3uf75dj019v12vT989/5
    3tL/z1LCTOz/6MfwxS6/JSOvG+D33u//7Pv//CWzHG7badDwzev76/P/7sT2wdHxz0y+RSm1ITDCKLLmrk7LRsj7xVPOTOr86bbxs0O9O2XJX23MZzG2KH3T
    eNXx1De2L4rYhdb31Of45zy5Nc/8zHjRcrXssr31ukjIQCuzI/3/9iaxHj3DNTO7K6XmoXfccGfWYTO+K67uqsr/xqrlpxysE8Dwvcz3yYHVfK3pqVzSVRmt
    Ex+uF4njg9f91YXXf4XWgEfLPxurE6OFYTUAAAAqdFJOUwD+/vfB8f5kiWBoo2DfNIzM1h0FoOxZ0uH0o8ETtjQTBQX0tr/FNjIdHUb5dt8AABHjSURBVHja
    7Fj7c9vGEY5Uu46TurbrOHWdtpkknSTlHYgD+DBNcjIaDksLIMfTGXqGYEjKFBFTlDyShlRo0XyopCzJelBvy3rZkt3+o907ABRBSaCk/KodEQJwuNtvH7e3
    u598ckmXdEmXdEmX1I2+/v76zftf3b5399s1oOePHj16/ohe9Qt7eK6/Mugvd+/d/sf9T6///evfyPyf177rWVtbX9+fnJwsFosLCwsPzkDwWXGhWIQ5k/u/
    +9tnf7oo92+u3TpYW59cWN6QJLtNI6RdMLsi4yXibMfHOUla2VhefvD7/1758s5F+AP79eKyBEsy7vSC2T/Gzc7r7LqN2/s3Jh7f+MO52f8A7BeAO12Xp0vx
    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
    QmCC
""".trimIndent()

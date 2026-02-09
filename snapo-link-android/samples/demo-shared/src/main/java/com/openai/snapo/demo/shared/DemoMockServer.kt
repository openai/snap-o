package com.openai.snapo.demo.shared

import android.util.Log
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.net.InetAddress

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
    val formBody = """{"ok":true,"endpoint":"form-post","source":"mockwebserver"}"""
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

fun String.toWebSocketUrl(): String {
    return when {
        startsWith("http://") -> "ws://${removePrefix("http://")}"
        startsWith("https://") -> "wss://${removePrefix("https://")}"
        else -> this
    }
}

private const val DemoLogTag: String = "SnapODemo"
private const val MockHost: String = "127.0.0.1"

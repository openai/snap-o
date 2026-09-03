package com.openai.snapo.demo.shared

import com.openai.snapo.demo.shared.tasks.TasksApi
import java.io.Closeable

enum class DemoAction(val title: String) {
    GetRequest("Network Request"),
    PostRequest("POST Request"),
    FormPost("Form POST"),
    UnknownLengthGzipPost("POST gzip (unknown length)"),
    NoContentTypeText("GET text (no Content-Type)"),
    Image("GET image (PNG)"),
    CompleteLargeResponse("GET 7 MB JSON (complete)"),
    TruncatedLargeResponse("GET 9 MB JSON (truncated)"),
    Sse("GET SSE stream"),
    SlowResponse("Slow response"),
    WebSocketEcho("WebSocket Echo"),
}

interface DemoClient : Closeable {
    val tasksApi: TasksApi

    /** Return null for unsupported actions. Use an exhaustive when without else so new actions require review. */
    fun handlerFor(action: DemoAction): (suspend () -> Unit)?
}

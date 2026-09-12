package com.example.snapo.tool

import com.openai.snapo.tool.ToolServer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

internal fun exampleServer(): ToolServer {
    val counter = MutableStateFlow(0L)
    return ToolServer(SnapOTool.ID) {
        get("/example") { respondJson(fakeSnapshot(counter.value)) }
        post("/example/increment") {
            counter.update { it + 1 }
            respondJson(fakeSnapshot(counter.value))
        }
        sse("/example/events") {
            counter.collect { value -> send(fakeSnapshot(value), event = "snapshot") }
        }
    }
}

// The counter is process-local sample state; no app data is collected or persisted.
private fun fakeSnapshot(counter: Long) = """
    {"protocolVersion":${SnapOTool.PROTOCOL_VERSION},"revision":$counter,"items":[
      {"id":"sample-1","name":"Sample string","value":"Hello from Example"},
      {"id":"sample-2","name":"Fake counter","value":$counter},
      {"id":"sample-3","name":"Sample boolean","value":true}
    ]}
""".trimIndent()

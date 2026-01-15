package com.openai.snapo.desktop.ui.inspector

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestId
import com.openai.snapo.desktop.inspector.NetworkInspectorWebSocketId
import com.openai.snapo.desktop.ui.json.JsonOutlineExpansionState

@Stable
class InspectorUiStateStore {
    private val requestStates = mutableMapOf<NetworkInspectorRequestId, RequestDetailUiState>()
    private val webSocketStates = mutableMapOf<NetworkInspectorWebSocketId, WebSocketDetailUiState>()

    fun requestState(id: NetworkInspectorRequestId): RequestDetailUiState {
        return requestStates.getOrPut(id) { RequestDetailUiState() }
    }

    fun webSocketState(id: NetworkInspectorWebSocketId): WebSocketDetailUiState {
        return webSocketStates.getOrPut(id) { WebSocketDetailUiState() }
    }
}

@Stable
class RequestDetailUiState {
    var requestHeadersExpanded by mutableStateOf(false)
    var requestBodyExpanded by mutableStateOf(false)
    var responseHeadersExpanded by mutableStateOf(true)
    var responseBodyExpanded by mutableStateOf(true)
    var streamExpanded by mutableStateOf(true)

    val requestBodyJsonState = JsonOutlineExpansionState(initiallyExpanded = true)
    val responseBodyJsonState = JsonOutlineExpansionState(initiallyExpanded = true)

    private val streamEventJsonStates = mutableMapOf<Long, JsonOutlineExpansionState>()

    fun streamEventJsonState(eventId: Long): JsonOutlineExpansionState {
        return streamEventJsonStates.getOrPut(eventId) { JsonOutlineExpansionState(initiallyExpanded = false) }
    }
}

@Stable
class WebSocketDetailUiState {
    var requestHeadersExpanded by mutableStateOf(false)
    var responseHeadersExpanded by mutableStateOf(true)
    var messagesExpanded by mutableStateOf(true)

    private val messageJsonStates = mutableMapOf<String, JsonOutlineExpansionState>()

    fun messageJsonState(messageId: String): JsonOutlineExpansionState {
        return messageJsonStates.getOrPut(messageId) { JsonOutlineExpansionState(initiallyExpanded = false) }
    }
}

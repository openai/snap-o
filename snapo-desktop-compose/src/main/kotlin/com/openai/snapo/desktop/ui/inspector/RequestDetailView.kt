@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.openai.snapo.desktop.inspector.NetworkInspectorCopyExporter
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestStatus
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestUiModel
import com.openai.snapo.desktop.inspector.NetworkInspectorStatusPresentation
import com.openai.snapo.desktop.ui.TriangleIndicator
import com.openai.snapo.desktop.ui.json.JsonOutlineExpansionState
import com.openai.snapo.desktop.ui.theme.SnapOAccents
import com.openai.snapo.desktop.ui.theme.SnapOMono
import com.openai.snapo.desktop.ui.theme.Spacings
import kotlinx.coroutines.delay

@Composable
fun RequestDetailView(
    request: NetworkInspectorRequestUiModel,
    uiStateStore: InspectorUiStateStore,
) {
    val uiState = remember(request.id) { uiStateStore.requestState(request.id) }

    var requestBodyPretty by remember(request.id) { mutableStateOf(request.requestBody?.prettyPrintedText != null) }
    var responseBodyPretty by remember(request.id) { mutableStateOf(request.responseBody?.prettyPrintedText != null) }

    var didCopyAllEvents by remember(request.id) { mutableStateOf(false) }

    val state = RequestDetailState(
        request = request,
        requestHeadersExpanded = uiState.requestHeadersExpanded,
        requestBodyExpanded = uiState.requestBodyExpanded,
        responseHeadersExpanded = uiState.responseHeadersExpanded,
        responseBodyExpanded = uiState.responseBodyExpanded,
        streamExpanded = uiState.streamExpanded,
        requestBodyJsonState = uiState.requestBodyJsonState,
        responseBodyJsonState = uiState.responseBodyJsonState,
        streamEventJsonStateProvider = uiState::streamEventJsonState,
        requestBodyPretty = requestBodyPretty,
        responseBodyPretty = responseBodyPretty,
        didCopyAllEvents = didCopyAllEvents,
    )
    val actions = RequestDetailActions(
        onRequestHeadersExpandedChange = { uiState.requestHeadersExpanded = it },
        onRequestBodyExpandedChange = { uiState.requestBodyExpanded = it },
        onResponseHeadersExpandedChange = { uiState.responseHeadersExpanded = it },
        onResponseBodyExpandedChange = { uiState.responseBodyExpanded = it },
        onStreamExpandedChange = { uiState.streamExpanded = it },
        onRequestBodyPrettyChange = { requestBodyPretty = it },
        onResponseBodyPrettyChange = { responseBodyPretty = it },
        onCopyAllEvents = {
            NetworkInspectorCopyExporter.copyStreamEventsRaw(request.streamEvents)
            didCopyAllEvents = true
        },
    )

    RequestDetailContent(
        state = state,
        actions = actions,
    )

    if (didCopyAllEvents) {
        LaunchedEffect(request.id, didCopyAllEvents) {
            delay(1_000)
            didCopyAllEvents = false
        }
    }
}

private data class RequestDetailState(
    val request: NetworkInspectorRequestUiModel,
    val requestHeadersExpanded: Boolean,
    val requestBodyExpanded: Boolean,
    val responseHeadersExpanded: Boolean,
    val responseBodyExpanded: Boolean,
    val streamExpanded: Boolean,
    val requestBodyJsonState: JsonOutlineExpansionState,
    val responseBodyJsonState: JsonOutlineExpansionState,
    val streamEventJsonStateProvider: (Long) -> JsonOutlineExpansionState,
    val requestBodyPretty: Boolean,
    val responseBodyPretty: Boolean,
    val didCopyAllEvents: Boolean,
)

private data class RequestDetailActions(
    val onRequestHeadersExpandedChange: (Boolean) -> Unit,
    val onRequestBodyExpandedChange: (Boolean) -> Unit,
    val onResponseHeadersExpandedChange: (Boolean) -> Unit,
    val onResponseBodyExpandedChange: (Boolean) -> Unit,
    val onStreamExpandedChange: (Boolean) -> Unit,
    val onRequestBodyPrettyChange: (Boolean) -> Unit,
    val onResponseBodyPrettyChange: (Boolean) -> Unit,
    val onCopyAllEvents: () -> Unit,
)

@Composable
private fun RequestDetailContent(
    state: RequestDetailState,
    actions: RequestDetailActions,
) {
    val request = state.request
    InspectorDetailScaffold {
        HeaderSummary(
            request = request,
            modifier = Modifier.padding(start = Spacings.xs, end = Spacings.xs, bottom = Spacings.md),
        )

        RequestHeadersSection(state, actions)
        RequestBodySection(state, actions)
        PendingResponseSection(request)
        ResponseHeadersSection(state, actions)

        if (request.isStreamingResponse) {
            StreamEventsSection(
                request = request,
                streamExpanded = state.streamExpanded,
                onStreamExpandedChange = actions.onStreamExpandedChange,
                didCopyAllEvents = state.didCopyAllEvents,
                onCopyAllEvents = actions.onCopyAllEvents,
                streamEventJsonStateProvider = state.streamEventJsonStateProvider,
            )
        }

        ResponseBodySection(state, actions)
    }
}

@Composable
private fun RequestHeadersSection(
    state: RequestDetailState,
    actions: RequestDetailActions,
) {
    val request = state.request
    if (request.requestHeaders.isEmpty()) return
    HeadersSection(
        title = "Request Headers",
        headers = request.requestHeaders,
        isExpanded = state.requestHeadersExpanded,
        onExpandedChange = actions.onRequestHeadersExpandedChange,
    )
}

@Composable
private fun RequestBodySection(
    state: RequestDetailState,
    actions: RequestDetailActions,
) {
    val request = state.request
    val payload = request.requestBody ?: return
    BodySection(
        title = "Request Body",
        payload = payload,
        isExpanded = state.requestBodyExpanded,
        onExpandedChange = actions.onRequestBodyExpandedChange,
        usePrettyPrinted = state.requestBodyPretty,
        onPrettyPrintedChange = actions.onRequestBodyPrettyChange,
        jsonOutlineState = state.requestBodyJsonState,
    )
}

@Composable
private fun PendingResponseSection(request: NetworkInspectorRequestUiModel) {
    if (request.status !is NetworkInspectorRequestStatus.Pending) return
    Text(
        "Waiting for response...",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun ResponseHeadersSection(
    state: RequestDetailState,
    actions: RequestDetailActions,
) {
    val request = state.request
    if (request.responseHeaders.isEmpty()) return
    HeadersSection(
        title = "Response Headers",
        headers = request.responseHeaders,
        isExpanded = state.responseHeadersExpanded,
        onExpandedChange = actions.onResponseHeadersExpandedChange,
    )
}

@Composable
private fun ResponseBodySection(
    state: RequestDetailState,
    actions: RequestDetailActions,
) {
    val request = state.request
    val payload = request.responseBody ?: return
    BodySection(
        title = "Response Body",
        payload = payload,
        isExpanded = state.responseBodyExpanded,
        onExpandedChange = actions.onResponseBodyExpandedChange,
        usePrettyPrinted = state.responseBodyPretty,
        onPrettyPrintedChange = actions.onResponseBodyPrettyChange,
        jsonOutlineState = state.responseBodyJsonState,
    )
}

@Composable
private fun StreamEventsSection(
    request: NetworkInspectorRequestUiModel,
    streamExpanded: Boolean,
    onStreamExpandedChange: (Boolean) -> Unit,
    didCopyAllEvents: Boolean,
    onCopyAllEvents: () -> Unit,
    streamEventJsonStateProvider: (Long) -> JsonOutlineExpansionState,
) {
    StreamEventsHeader(
        isExpanded = streamExpanded,
        onExpandedChange = onStreamExpandedChange,
        hasEvents = request.streamEvents.isNotEmpty(),
        didCopyAll = didCopyAllEvents,
        onCopyAll = onCopyAllEvents,
    )

    if (streamExpanded) {
        if (request.streamEvents.isEmpty()) {
            Text(
                "Awaiting events...",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            request.streamEvents.forEach { event ->
                key(event.id) {
                    StreamEventCard(
                        event = event,
                        jsonOutlineState = streamEventJsonStateProvider(event.id),
                        modifier = Modifier.padding(bottom = Spacings.md),
                    )
                }
            }
        }

        request.streamClosed?.let { closed ->
            StreamClosedInfo(closed = closed)
        }
    }
}

@Composable
private fun HeaderSummary(
    request: NetworkInspectorRequestUiModel,
    modifier: Modifier = Modifier,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacings.md), modifier = modifier) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        request.method,
                        style = MaterialTheme.typography.titleMediumEmphasized,
                        modifier = Modifier.padding(end = Spacings.lg),
                    )
                    SelectionContainer {
                        Text(
                            request.url,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacings.lg),
        ) {
            StatusBadge(request)
            AdaptiveTimingText(timing = request.timing, status = request.status)
        }

        val status = request.status
        if (status is NetworkInspectorRequestStatus.Failure) {
            val message = status.message
            if (!message.isNullOrBlank()) {
                Text(
                    "Error: $message",
                    style = MaterialTheme.typography.bodySmall,
                    color = SnapOAccents.current().error,
                )
            }
        }
    }
}

@Composable
private fun StatusBadge(request: NetworkInspectorRequestUiModel) {
    val status = request.status
    val (label, color) = when {
        request.isStreamingResponse && request.streamClosed == null ->
            "Streaming" to SnapOAccents.current().accentBlue
        status is NetworkInspectorRequestStatus.Pending ->
            "Pending" to MaterialTheme.colorScheme.onSurfaceVariant
        status is NetworkInspectorRequestStatus.Success -> {
            val code = status.code
            NetworkInspectorStatusPresentation.displayName(code) to NetworkInspectorStatusPresentation.color(code)
        }
        status is NetworkInspectorRequestStatus.Failure -> "Error" to SnapOAccents.current().error
        else -> "Done" to MaterialTheme.colorScheme.onSurfaceVariant
    }

    Text(
        text = label,
        style = MaterialTheme.typography.labelSmall,
        color = color,
    )
}

@Composable
private fun StreamEventsHeader(
    isExpanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    hasEvents: Boolean,
    didCopyAll: Boolean,
    onCopyAll: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clickable(interactionSource = null, indication = null) { onExpandedChange(!isExpanded) }
                .padding(vertical = Spacings.xs),
        ) {
            TriangleIndicator(expanded = isExpanded)
            Spacer(Modifier.size(Spacings.xxs))
            Text("Server-Sent Events", style = MaterialTheme.typography.titleSmallEmphasized)
        }

        Spacer(Modifier.weight(1f))

        if (hasEvents) {
            TextButton(onClick = onCopyAll) {
                Text(if (didCopyAll) "Copied" else "Copy All")
            }
        }
    }
}

@Composable
private fun StreamClosedInfo(closed: NetworkInspectorRequestUiModel.StreamClosed) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacings.xs)) {
        Text(
            "Stream closed (${closed.reason}) at ${closed.timestamp}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!closed.message.isNullOrBlank()) {
            Text(
                "Message: ${closed.message}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            "Total events: ${closed.totalEvents} • Total bytes: ${closed.totalBytes}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun StreamEventCard(
    event: NetworkInspectorRequestUiModel.StreamEvent,
    jsonOutlineState: JsonOutlineExpansionState,
    modifier: Modifier = Modifier,
) {
    val prettyText = remember(event.id) { event.data?.let(::prettyPrintedJsonOrNull) }
    var pretty by remember(event.id) { mutableStateOf(prettyText != null) }
    val isLikelyJson = isLikelyJsonPayload(event.data, prettyText)

    InspectorCard(modifier = modifier) {
        val displayText = if (pretty && !prettyText.isNullOrBlank()) prettyText else (event.data ?: event.raw)
        StreamEventHeader(
            event = event,
            prettyText = prettyText,
            pretty = pretty,
            onTogglePretty = { pretty = !pretty },
            displayText = displayText,
        )

        InspectorPayloadView(
            rawText = event.data ?: event.raw,
            prettyText = prettyText,
            isLikelyJson = isLikelyJson,
            usePrettyPrinted = pretty,
            onPrettyPrintedChange = { pretty = it },
            prettyInitiallyExpanded = false,
            showsToggle = false,
            showsCopyButton = false,
            jsonOutlineState = jsonOutlineState,
            modifier = Modifier.fillMaxWidth(),
        )

        StreamEventMetadata(event)
    }
}

private fun isLikelyJsonPayload(
    data: String?,
    prettyText: String?,
): Boolean {
    if (prettyText != null) return true
    val first = data?.trim()?.firstOrNull()
    return first == '{' || first == '['
}

@Composable
private fun StreamEventHeader(
    event: NetworkInspectorRequestUiModel.StreamEvent,
    prettyText: String?,
    pretty: Boolean,
    onTogglePretty: () -> Unit,
    displayText: String,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            "#${event.sequence}",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(end = Spacings.md),
        )
        Text(
            event.timestamp.toString(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(end = Spacings.md),
        )
        if (!event.eventName.isNullOrBlank()) {
            Text(
                event.eventName,
                style = MaterialTheme.typography.labelSmallEmphasized,
            )
        }

        Spacer(Modifier.weight(1f))

        StreamEventActions(
            prettyText = prettyText,
            pretty = pretty,
            onTogglePretty = onTogglePretty,
            displayText = displayText,
        )
    }
}

@Composable
private fun StreamEventActions(
    prettyText: String?,
    pretty: Boolean,
    onTogglePretty: () -> Unit,
    displayText: String,
) {
    var copyToken by remember(displayText) { mutableIntStateOf(0) }
    val didCopy = copyToken != 0
    LaunchedEffect(copyToken, displayText) {
        if (copyToken == 0) return@LaunchedEffect
        val activeToken = copyToken
        delay(1_000)
        if (copyToken == activeToken) copyToken = 0
    }
    val onCopy = {
        NetworkInspectorCopyExporter.copyText(displayText)
        copyToken += 1
    }
    Row(
        horizontalArrangement = Arrangement.spacedBy(Spacings.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (prettyText != null) {
            InspectorInlineTextToggle(
                label = if (pretty) "PRETTY" else "RAW",
                onClick = onTogglePretty,
            )
        }
        InspectorInlineCopyButton(
            isCopied = didCopy,
            enabled = displayText.isNotBlank(),
            onCopy = onCopy,
        )
    }
}

@Composable
private fun StreamEventMetadata(event: NetworkInspectorRequestUiModel.StreamEvent) {
    if (
        event.comment.isNullOrBlank() &&
        event.lastEventId.isNullOrBlank() &&
        event.retryMillis == null
    ) {
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(Spacings.xxs)) {
        if (!event.comment.isNullOrBlank()) {
            Text(
                "Comment: ${event.comment}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontFamily = SnapOMono,
            )
        }
        if (!event.lastEventId.isNullOrBlank()) {
            Text(
                "Last-Event-ID: ${event.lastEventId}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontFamily = SnapOMono,
            )
        }
        if (event.retryMillis != null) {
            Text(
                "Retry: ${event.retryMillis} ms",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                fontFamily = SnapOMono,
            )
        }
    }
}

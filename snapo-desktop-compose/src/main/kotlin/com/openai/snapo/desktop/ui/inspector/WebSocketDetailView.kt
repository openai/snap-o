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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openai.snapo.desktop.generated.resources.Res
import com.openai.snapo.desktop.generated.resources.inbox_24px
import com.openai.snapo.desktop.generated.resources.send_24px
import com.openai.snapo.desktop.inspector.Header
import com.openai.snapo.desktop.inspector.NetworkInspectorCopyExporter
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestStatus
import com.openai.snapo.desktop.inspector.NetworkInspectorStatusPresentation
import com.openai.snapo.desktop.inspector.NetworkInspectorWebSocketUiModel
import com.openai.snapo.desktop.inspector.WebSocketMessage
import com.openai.snapo.desktop.ui.TriangleIndicator
import com.openai.snapo.desktop.ui.json.JsonOutlineExpansionState
import com.openai.snapo.desktop.ui.theme.SnapOAccents
import com.openai.snapo.desktop.ui.theme.SnapOMono
import com.openai.snapo.desktop.ui.theme.Spacings
import kotlinx.coroutines.delay
import org.jetbrains.compose.resources.DrawableResource
import org.jetbrains.compose.resources.painterResource
import java.time.Instant
import java.time.ZoneId
import java.time.chrono.Chronology
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.FormatStyle
import java.util.Locale

@Composable
fun WebSocketDetailView(
    webSocket: NetworkInspectorWebSocketUiModel,
    uiStateStore: InspectorUiStateStore,
    modifier: Modifier = Modifier,
) {
    val uiState = remember(webSocket.id) { uiStateStore.webSocketState(webSocket.id) }

    InspectorDetailScaffold(modifier = modifier) {
        item(key = "websocket:header") {
            HeaderSummary(webSocket = webSocket, modifier = Modifier.padding(bottom = Spacings.md))
        }

        headersSectionItems(
            title = "Request Headers",
            headers = webSocket.requestHeaders,
            isExpanded = uiState.requestHeadersExpanded,
            onExpandedChange = { uiState.requestHeadersExpanded = it },
            keyPrefix = "ws-request-headers",
        )

        headersSectionItems(
            title = "Response Headers",
            headers = webSocket.responseHeaders,
            isExpanded = uiState.responseHeadersExpanded,
            onExpandedChange = { uiState.responseHeadersExpanded = it },
            keyPrefix = "ws-response-headers",
        )

        item(key = "ws-messages:header") {
            DisableSelection {
                MessagesSectionHeader(
                    isExpanded = uiState.messagesExpanded,
                    onExpandedChange = { uiState.messagesExpanded = it },
                )
            }
        }

        if (uiState.messagesExpanded) {
            if (webSocket.messages.isEmpty()) {
                item(key = "ws-messages:empty") {
                    Text(
                        "No messages yet",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = Spacings.mdPlus, top = Spacings.md),
                    )
                }
            } else {
                webSocket.messages.forEach { message ->
                    item(key = "ws-message:${message.id}") {
                        MessageCard(
                            message = message,
                            jsonOutlineState = uiState.messageJsonState(message.id),
                            modifier = Modifier.padding(bottom = Spacings.sm),
                        )
                    }
                }
            }
        }
    }
}

private fun LazyListScope.headersSectionItems(
    title: String,
    headers: List<Header>,
    isExpanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    keyPrefix: String,
) {
    if (headers.isEmpty()) return
    item(key = "$keyPrefix:header") {
        HeadersSectionHeader(
            title = title,
            isExpanded = isExpanded,
            onExpandedChange = onExpandedChange,
        )
    }
    if (isExpanded) {
        item(key = "$keyPrefix:body") {
            HeadersSectionBody(
                headers = headers,
                modifier = Modifier.padding(top = Spacings.sm, bottom = Spacings.xs),
            )
        }
    }
}

@Composable
private fun HeaderSummary(
    webSocket: NetworkInspectorWebSocketUiModel,
    modifier: Modifier = Modifier,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Spacings.md), modifier = modifier) {
        WebSocketHeaderRow(webSocket = webSocket)

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Spacings.lg),
        ) {
            StatusBadge(webSocket)
            AdaptiveTimingText(timing = webSocket.timing, status = webSocket.status)
        }

        WebSocketFailureMessage(status = webSocket.status)
        WebSocketCloseDetails(webSocket = webSocket)
    }
}

@Composable
private fun WebSocketHeaderRow(
    webSocket: NetworkInspectorWebSocketUiModel,
) {
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    webSocket.method,
                    style = MaterialTheme.typography.titleMediumEmphasized,
                    modifier = Modifier.padding(end = Spacings.lg),
                )
                SelectionContainer {
                    Text(
                        webSocket.url,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
}

@Composable
private fun WebSocketFailureMessage(status: NetworkInspectorRequestStatus) {
    if (status !is NetworkInspectorRequestStatus.Failure) return
    val message = status.message
    if (!message.isNullOrBlank()) {
        Text(
            "Error: $message",
            style = MaterialTheme.typography.bodySmall,
            color = SnapOAccents.current().error,
        )
    }
}

@Composable
private fun WebSocketCloseDetails(webSocket: NetworkInspectorWebSocketUiModel) {
    val closeRequested = webSocket.closeRequested
    val closing = webSocket.closing
    val closed = webSocket.closed
    if (closeRequested == null && closing == null && closed == null) return

    Column(
        verticalArrangement = Arrangement.spacedBy(Spacings.xs),
    ) {
        if (closeRequested != null) {
            val acceptance = if (closeRequested.accepted) "accepted" else "not accepted"
            val initiator = closeRequested.initiated.replaceFirstChar { it.uppercase() }
            Text(
                "Close requested: ${closeRequested.code} • $initiator • $acceptance",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!closeRequested.reason.isNullOrBlank()) {
                Text(
                    "Reason: ${closeRequested.reason}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        if (closing != null) {
            Text(
                "Closing handshake: ${closing.code}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!closing.reason.isNullOrBlank()) {
                Text(
                    "Reason: ${closing.reason}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        if (closed != null) {
            Text(
                "Closed: ${closed.code}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!closed.reason.isNullOrBlank()) {
                Text(
                    "Reason: ${closed.reason}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun StatusBadge(webSocket: NetworkInspectorWebSocketUiModel) {
    val status = webSocket.status
    val (label, color) = when {
        webSocket.closed != null -> {
            val code = webSocket.closed.code
            NetworkInspectorStatusPresentation.displayName(code) to NetworkInspectorStatusPresentation.color(code)
        }
        webSocket.closing != null -> {
            val code = webSocket.closing.code
            NetworkInspectorStatusPresentation.displayName(code) to NetworkInspectorStatusPresentation.color(code)
        }
        webSocket.opened != null -> {
            val code = webSocket.opened.code
            NetworkInspectorStatusPresentation.displayName(code) to NetworkInspectorStatusPresentation.color(code)
        }
        status is NetworkInspectorRequestStatus.Pending ->
            "Pending" to MaterialTheme.colorScheme.onSurfaceVariant
        status is NetworkInspectorRequestStatus.Success -> {
            val code = status.code
            NetworkInspectorStatusPresentation.displayName(code) to NetworkInspectorStatusPresentation.color(code)
        }
        status is NetworkInspectorRequestStatus.Failure -> {
            val msg = status.message
            (msg?.takeIf { it.isNotBlank() } ?: "Failed") to SnapOAccents.current().error
        }
        else -> "Done" to MaterialTheme.colorScheme.onSurfaceVariant
    }

    Text(
        text = label,
        style = MaterialTheme.typography.labelSmall,
        color = color,
    )
}

@Composable
private fun MessageCard(
    message: NetworkInspectorWebSocketUiModel.Message,
    jsonOutlineState: JsonOutlineExpansionState,
    modifier: Modifier = Modifier,
) {
    val preview = message.preview.orEmpty()
    val pretty = remember(message.id) { preview.takeIf { it.isNotBlank() }?.let(::prettyPrintedJsonOrNull) }
    var usePretty by remember(message.id) { mutableStateOf(pretty != null) }
    val isLikelyJson = isLikelyJsonPayload(preview, pretty)
    val (icon, tint) = messageIconFor(message.direction)
    val displayText = if (usePretty && !pretty.isNullOrBlank()) pretty else preview

    InspectorCard(modifier = modifier) {
        MessageHeaderRow(
            message = message,
            icon = icon,
            tint = tint,
            prettyText = pretty,
            pretty = usePretty,
            onPrettyToggle = { usePretty = !usePretty },
            displayText = displayText,
        )

        MessagePayload(
            preview = preview,
            pretty = pretty,
            isLikelyJson = isLikelyJson,
            usePretty = usePretty,
            onPrettyChange = { usePretty = it },
            jsonOutlineState = jsonOutlineState,
        )
    }
}

@Composable
private fun MessagesSectionHeader(
    isExpanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(interactionSource = null, indication = null) { onExpandedChange(!isExpanded) }
            .padding(vertical = Spacings.xs),
    ) {
        TriangleIndicator(expanded = isExpanded)
        Spacer(Modifier.size(Spacings.xxs))
        Text(
            text = "Messages",
            style = MaterialTheme.typography.titleSmallEmphasized,
        )
    }
}

private fun isLikelyJsonPayload(preview: String, pretty: String?): Boolean {
    if (pretty != null) return true
    val first = preview.trim().firstOrNull()
    return first == '{' || first == '['
}

@Composable
private fun messageIconFor(
    direction: WebSocketMessage.Direction,
): Pair<DrawableResource, Color> {
    val accents = SnapOAccents.current()
    return when (direction) {
        WebSocketMessage.Direction.Outgoing -> {
            Res.drawable.send_24px to accents.accentBlue
        }
        WebSocketMessage.Direction.Incoming -> {
            Res.drawable.inbox_24px to accents.success
        }
    }
}

@Composable
private fun MessageHeaderRow(
    message: NetworkInspectorWebSocketUiModel.Message,
    icon: DrawableResource,
    tint: Color,
    prettyText: String?,
    pretty: Boolean,
    onPrettyToggle: () -> Unit,
    displayText: String,
) {
    val timestampLabel = remember(message.timestamp) { formatInspectorTimestamp(message.timestamp) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(
            painter = painterResource(icon),
            contentDescription = null,
            tint = tint,
            modifier = Modifier.padding(horizontal = Spacings.xxs).size(20.dp),
        )

        Spacer(Modifier.size(Spacings.xs))

        if (message.payloadSize != null) {
            Text(
                "${message.payloadSize} bytes",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(end = Spacings.md),
            )
        }

        if (message.enqueued != null) {
            Text(
                if (message.enqueued) "enqueued" else "immediate",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(end = Spacings.md),
            )
        }

        Text(
            timestampLabel,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(end = Spacings.md),
        )

        Text(
            message.opcode,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = SnapOMono,
        )

        Spacer(Modifier.weight(1f))

        MessageHeaderActions(
            prettyText = prettyText,
            pretty = pretty,
            onPrettyToggle = onPrettyToggle,
            displayText = displayText,
        )
    }
}

@Composable
private fun MessagePayload(
    preview: String,
    pretty: String?,
    isLikelyJson: Boolean,
    usePretty: Boolean,
    onPrettyChange: (Boolean) -> Unit,
    jsonOutlineState: JsonOutlineExpansionState,
) {
    if (preview.isNotBlank()) {
        InspectorPayloadView(
            rawText = preview,
            prettyText = pretty,
            isLikelyJson = isLikelyJson,
            usePrettyPrinted = usePretty,
            onPrettyPrintedChange = onPrettyChange,
            prettyInitiallyExpanded = false,
            showsToggle = false,
            showsCopyButton = false,
            jsonOutlineState = jsonOutlineState,
            modifier = Modifier.fillMaxWidth(),
        )
    } else if (isLikelyJson) {
        Text(
            "Unable to pretty print (invalid or truncated JSON)",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun MessageHeaderActions(
    prettyText: String?,
    pretty: Boolean,
    onPrettyToggle: () -> Unit,
    displayText: String,
) {
    if (prettyText == null && displayText.isEmpty()) return

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
    DisableSelection {
        Row(
            horizontalArrangement = Arrangement.spacedBy(Spacings.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (prettyText != null) {
                InspectorInlineTextToggle(
                    label = if (pretty) "PRETTY" else "RAW",
                    onClick = onPrettyToggle,
                )
            }
            if (displayText.isNotEmpty()) {
                InspectorInlineCopyButton(
                    isCopied = didCopy,
                    onCopy = onCopy,
                )
            }
        }
    }
}

private fun formatInspectorTimestamp(instant: Instant): String {
    val locale = Locale.getDefault()
    val zoneId = ZoneId.systemDefault()
    val pattern = localizedTimePatternWithMillis(locale)
    val formatter = DateTimeFormatter.ofPattern(pattern, locale).withZone(zoneId)
    return formatter.format(instant)
}

private fun localizedTimePatternWithMillis(locale: Locale): String {
    val basePattern = DateTimeFormatterBuilder.getLocalizedDateTimePattern(
        null,
        FormatStyle.MEDIUM,
        Chronology.ofLocale(locale),
        locale,
    )
    val lastSecondIndex = lastUnquotedIndexOf(basePattern, 's')
    return if (lastSecondIndex >= 0) {
        buildString {
            append(basePattern, 0, lastSecondIndex + 1)
            append(".SSS")
            append(basePattern.substring(lastSecondIndex + 1))
        }
    } else {
        "$basePattern.SSS"
    }
}

private fun lastUnquotedIndexOf(pattern: String, target: Char): Int {
    var inQuote = false
    var lastIndex = -1
    var index = 0
    while (index < pattern.length) {
        val char = pattern[index]
        if (char == '\'') {
            if (index + 1 < pattern.length && pattern[index + 1] == '\'') {
                index += 2
            } else {
                inQuote = !inQuote
                index += 1
            }
        } else {
            if (!inQuote && char == target) {
                lastIndex = index
            }
            index += 1
        }
    }
    return lastIndex
}

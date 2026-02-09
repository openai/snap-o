package com.openai.snapo.desktop.inspector

import java.net.URI
import java.time.Instant

enum class ListSortOrder {
    OldestFirst,
    NewestFirst,
}

sealed interface NetworkInspectorItemId {
    data class Request(val id: NetworkInspectorRequestId) : NetworkInspectorItemId
    data class WebSocket(val id: NetworkInspectorWebSocketId) : NetworkInspectorItemId
}

sealed interface NetworkInspectorRequestStatus {
    data object Pending : NetworkInspectorRequestStatus
    data class Success(val code: Int) : NetworkInspectorRequestStatus
    data class Failure(val message: String?) : NetworkInspectorRequestStatus
}

data class NetworkInspectorServerUiModel(
    val id: SnapOLinkServerId,
    val displayName: String,
    val deviceDisplayTitle: String,
    val isConnected: Boolean,
    val deviceId: String,
    val pid: Int?,
    val appIconBase64: String?,
    val schemaVersion: Int?,
    val isSchemaNewerThanSupported: Boolean,
    val isSchemaOlderThanSupported: Boolean,
    val hasHello: Boolean,
    val features: Set<String>,
) {
    companion object {
        fun from(server: SnapOLinkServer): NetworkInspectorServerUiModel {
            val displayName = when {
                server.hello != null -> server.hello.packageName
                !server.packageNameHint.isNullOrBlank() -> server.packageNameHint
                else -> server.socketName
            }

            return NetworkInspectorServerUiModel(
                id = server.id,
                displayName = displayName,
                deviceDisplayTitle = server.deviceDisplayTitle,
                isConnected = server.isConnected,
                deviceId = server.deviceId,
                pid = server.hello?.pid,
                appIconBase64 = server.appIcon?.base64Data,
                schemaVersion = server.schemaVersion,
                isSchemaNewerThanSupported = server.isSchemaNewerThanSupported,
                isSchemaOlderThanSupported = server.isSchemaOlderThanSupported,
                hasHello = server.hasHello,
                features = server.features,
            )
        }
    }
}

data class NetworkInspectorRequestSummary(
    val id: NetworkInspectorRequestId,
    val serverId: SnapOLinkServerId,
    val method: String,
    val url: String,
    val primaryPathComponent: String,
    val secondaryPath: String,
    val status: NetworkInspectorRequestStatus,
    val isStreamingResponse: Boolean,
    val hasClosedStream: Boolean,
    val firstSeenAt: Instant,
    val lastUpdatedAt: Instant,
)

data class NetworkInspectorWebSocketSummary(
    val id: NetworkInspectorWebSocketId,
    val serverId: SnapOLinkServerId,
    val method: String,
    val url: String,
    val primaryPathComponent: String,
    val secondaryPath: String,
    val status: NetworkInspectorRequestStatus,
    val showsActiveIndicator: Boolean,
    val firstSeenAt: Instant,
    val lastUpdatedAt: Instant,
)

data class NetworkInspectorListItemUiModel(
    val kind: Kind,
    val firstSeenAt: Instant,
) {
    sealed interface Kind {
        data class Request(val value: NetworkInspectorRequestSummary) : Kind
        data class WebSocket(val value: NetworkInspectorWebSocketSummary) : Kind
    }

    val id: NetworkInspectorItemId
        get() = when (kind) {
            is Kind.Request -> NetworkInspectorItemId.Request(kind.value.id)
            is Kind.WebSocket -> NetworkInspectorItemId.WebSocket(kind.value.id)
        }

    val serverId: SnapOLinkServerId
        get() = when (kind) {
            is Kind.Request -> kind.value.serverId
            is Kind.WebSocket -> kind.value.serverId
        }

    val method: String
        get() = when (kind) {
            is Kind.Request -> {
                val req = kind.value
                if (req.isStreamingResponse && !req.hasClosedStream) "${req.method} SSE" else req.method
            }
            is Kind.WebSocket -> kind.value.method
        }

    val url: String
        get() = when (kind) {
            is Kind.Request -> kind.value.url
            is Kind.WebSocket -> kind.value.url
        }

    val primaryPathComponent: String
        get() = when (kind) {
            is Kind.Request -> kind.value.primaryPathComponent
            is Kind.WebSocket -> kind.value.primaryPathComponent
        }

    val secondaryPath: String
        get() = when (kind) {
            is Kind.Request -> kind.value.secondaryPath
            is Kind.WebSocket -> kind.value.secondaryPath
        }

    val status: NetworkInspectorRequestStatus
        get() = when (kind) {
            is Kind.Request -> kind.value.status
            is Kind.WebSocket -> kind.value.status
        }

    val showsActiveIndicator: Boolean
        get() = when (kind) {
            is Kind.Request -> kind.value.isStreamingResponse && !kind.value.hasClosedStream
            is Kind.WebSocket -> kind.value.showsActiveIndicator
        }

    val isPending: Boolean
        get() = status is NetworkInspectorRequestStatus.Pending
}

internal fun requestSummary(request: NetworkInspectorRequest): NetworkInspectorRequestSummary {
    val method = request.request?.method ?: "?"
    val url = request.request?.url ?: "Request ${request.requestId}"

    val status = when {
        request.failure != null -> NetworkInspectorRequestStatus.Failure(request.failure.message)
        request.response != null -> NetworkInspectorRequestStatus.Success(request.response.code)
        else -> NetworkInspectorRequestStatus.Pending
    }

    val (primary, secondary) = splitPath(url, includeQueryInPrimary = true)

    val eventsSorted = request.streamEvents.sortedWith(
        compareBy<ResponseStreamEvent> { it.sequence }.thenBy { it.tWallMs }
    )
    val isStreaming = eventsSorted.isNotEmpty() || request.streamClosed != null

    return NetworkInspectorRequestSummary(
        id = request.id,
        serverId = request.serverId,
        method = method,
        url = url,
        primaryPathComponent = primary,
        secondaryPath = secondary,
        status = status,
        isStreamingResponse = isStreaming,
        hasClosedStream = request.streamClosed != null,
        firstSeenAt = request.firstSeenAt,
        lastUpdatedAt = request.lastUpdatedAt,
    )
}

internal fun webSocketSummary(session: NetworkInspectorWebSocket): NetworkInspectorWebSocketSummary {
    val urlString = session.willOpen?.url ?: "websocket://${session.socketId}"
    val scheme = try {
        URI(urlString).scheme
    } catch (_: Throwable) {
        null
    }
    val method = webSocketMethodBadge(scheme)

    val status = when {
        session.failed != null -> NetworkInspectorRequestStatus.Failure(session.failed.message)
        session.cancelled != null -> NetworkInspectorRequestStatus.Failure("Cancelled")
        session.closed != null -> NetworkInspectorRequestStatus.Success(session.closed.code)
        session.closing != null -> NetworkInspectorRequestStatus.Success(session.closing.code)
        session.opened != null -> NetworkInspectorRequestStatus.Success(session.opened.code)
        else -> NetworkInspectorRequestStatus.Pending
    }

    val (primary, secondary) = splitPath(urlString, includeQueryInPrimary = true)

    val isActive = session.cancelled == null && session.failed == null && session.closed == null

    return NetworkInspectorWebSocketSummary(
        id = session.id,
        serverId = session.serverId,
        method = method,
        url = urlString,
        primaryPathComponent = primary,
        secondaryPath = secondary,
        status = status,
        showsActiveIndicator = isActive,
        firstSeenAt = session.firstSeenAt,
        lastUpdatedAt = session.lastUpdatedAt,
    )
}

private fun webSocketMethodBadge(scheme: String?): String {
    if (scheme.isNullOrBlank()) return "WS"
    return when (scheme.lowercase()) {
        "http", "ws" -> "WS"
        "https", "wss" -> "WSS"
        else -> scheme.uppercase()
    }
}

private fun splitPath(url: String, includeQueryInPrimary: Boolean): Pair<String, String> {
    val uri = try {
        URI(url)
    } catch (_: Throwable) {
        return url to ""
    }

    val path = uri.path.orEmpty()
    val query = uri.rawQuery.orEmpty()
    val querySuffix = if (includeQueryInPrimary && query.isNotEmpty()) "?$query" else ""

    if (path.isNotBlank()) {
        val parts = path.split('/').filter { it.isNotBlank() }
        val primary = ((parts.lastOrNull() ?: path) + querySuffix)
        val remaining = parts.dropLast(1)
        val secondary = when {
            remaining.isNotEmpty() -> "/" + remaining.joinToString("/")
            parts.isNotEmpty() -> "/"
            else -> ""
        }
        return primary to secondary
    }

    // No path; fall back to host/query.
    val primary = (uri.host ?: url) + querySuffix
    return primary to ""
}

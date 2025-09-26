@file:OptIn(ExperimentalSerializationApi::class)

package com.openai.snapo.link.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** All records emitted over the wire are one-per-line NDJSON objects. */
@Serializable
sealed interface SnapONetRecord {
    val schemaVersion: String
}

@Serializable
data class Header(
    val name: String,
    val value: String,
)

sealed interface TimedRecord {
    val tWallMs: Long
    val tMonoNs: Long
}

/** Emitted first on every connection. */
@Serializable
@SerialName("Hello")
data class Hello(
    override val schemaVersion: String = SCHEMA_VERSION,
    val packageName: String,
    val processName: String,
    val pid: Int,
    val serverStartWallMs: Long,
    val serverStartMonoNs: Long,
    val mode: String, // "safe" or "unredacted" (placeholder for your pref)
    val capabilities: List<String> = listOf("network", "websocket", "app-icon"),
) : SnapONetRecord

/** Marker after snapshot dump completes. */
@Serializable
@SerialName("ReplayComplete")
data class ReplayComplete(
    override val schemaVersion: String = SCHEMA_VERSION,
) : SnapONetRecord

/** Optional icon metadata to help the desktop show the app branding. */
@Serializable
@SerialName("AppIcon")
data class AppIcon(
    override val schemaVersion: String = SCHEMA_VERSION,
    val packageName: String,
    val width: Int,
    val height: Int,
    val format: String = "png",
    val base64Data: String,
) : SnapONetRecord

/** Base for per-request events to let the desktop correlate rows. */
sealed interface PerRequestRecord : SnapONetRecord, TimedRecord {
    val id: String
}

/** Request line + headers + tiny, already-redacted preview (if any). */
@Serializable
@SerialName("RequestWillBeSent")
data class RequestWillBeSent(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val method: String,
    val url: String,
    @EncodeDefault
    val headers: List<Header> = emptyList(),
    val bodyPreview: String? = null, // already-truncated/redacted text, if provided by the source
    val body: String? = null,
    val bodyEncoding: String? = null,
    val bodyTruncatedBytes: Long? = null,
    val bodySize: Long? = null,
) : PerRequestRecord

/** Response line + headers + timing breakdown + body preview/full text (when available). */
@Serializable
@SerialName("ResponseReceived")
data class ResponseReceived(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    @EncodeDefault
    val headers: List<Header> = emptyList(),
    val bodyPreview: String? = null,
    val body: String? = null,
    val bodyTruncatedBytes: Long? = null, // number of bytes omitted from [body]; null when unknown
    val bodySize: Long? = null,
    val timings: Timings = Timings(),
) : PerRequestRecord

/** Failure with partial timings if available. */
@Serializable
@SerialName("RequestFailed")
data class RequestFailed(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val errorKind: String,
    val message: String? = null,
    @EncodeDefault
    val timings: Timings = Timings(),
) : PerRequestRecord

/** Incremental Server-Sent Event payload emitted while streaming. */
@Serializable
@SerialName("ResponseStreamEvent")
data class ResponseStreamEvent(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val sequence: Long,
    val event: String? = null,
    val data: String? = null,
    val lastEventId: String? = null,
    val retryMillis: Long? = null,
    val comment: String? = null,
    val raw: String,
) : PerRequestRecord

/** Indicates the streaming response completed or terminated. */
@Serializable
@SerialName("ResponseStreamClosed")
data class ResponseStreamClosed(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val reason: String,
    val message: String? = null,
    val totalEvents: Long,
    val totalBytes: Long,
) : PerRequestRecord

sealed interface PerWebSocketRecord : SnapONetRecord, TimedRecord {
    val id: String
}

@Serializable
@SerialName("WebSocketWillOpen")
data class WebSocketWillOpen(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val url: String,
    @EncodeDefault
    val headers: List<Header> = emptyList(),
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketOpened")
data class WebSocketOpened(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    @EncodeDefault
    val headers: List<Header> = emptyList(),
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketMessageSent")
data class WebSocketMessageSent(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val opcode: String,
    val preview: String? = null,
    val payloadSize: Long? = null,
    val enqueued: Boolean,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketMessageReceived")
data class WebSocketMessageReceived(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val opcode: String,
    val preview: String? = null,
    val payloadSize: Long? = null,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketClosing")
data class WebSocketClosing(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketClosed")
data class WebSocketClosed(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketFailed")
data class WebSocketFailed(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val errorKind: String,
    val message: String? = null,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketCloseRequested")
data class WebSocketCloseRequested(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
    val initiated: String = "client",
    val accepted: Boolean,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketCancelled")
data class WebSocketCancelled(
    @EncodeDefault
    override val schemaVersion: String = SCHEMA_VERSION,
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord

@Serializable
data class Timings(
    val dnsMs: Long? = null,
    val connectMs: Long? = null,
    val tlsMs: Long? = null,
    val requestHeadersMs: Long? = null,
    val requestBodyMs: Long? = null,
    val ttfbMs: Long? = null,
    val responseBodyMs: Long? = null,
    val totalMs: Long? = null,
)

internal const val SCHEMA_VERSION: String = "1.0"

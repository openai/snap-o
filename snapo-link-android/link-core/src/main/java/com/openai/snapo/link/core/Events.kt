@file:OptIn(ExperimentalSerializationApi::class)

package com.openai.snapo.link.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** All records emitted over the wire are one-per-line NDJSON objects. */
@Serializable
sealed interface SnapONetRecord

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
    val schemaVersion: Int = SCHEMA_VERSION,
    val packageName: String,
    val processName: String,
    val pid: Int,
    val serverStartWallMs: Long,
    val serverStartMonoNs: Long,
    val mode: String,
) : SnapONetRecord

/** Marker after snapshot dump completes. */
@Serializable
@SerialName("ReplayComplete")
class ReplayComplete : SnapONetRecord

/** Optional icon metadata to help the desktop show the app branding. */
@Serializable
@SerialName("AppIcon")
data class AppIcon(
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
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val method: String,
    val url: String,
    val headers: List<Header> = emptyList(),
    val body: String?,
    val bodyEncoding: String?,
    val bodyTruncatedBytes: Long?,
    val bodySize: Long?,
) : PerRequestRecord

/** Response line + headers + timing breakdown + body preview/full text (when available). */
@Serializable
@SerialName("ResponseReceived")
data class ResponseReceived(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val headers: List<Header> = emptyList(),
    val bodyPreview: String? = null,
    val body: String? = null,
    val bodyTruncatedBytes: Long? = null,
    val bodySize: Long? = null,
    val timings: Timings = Timings(),
) : PerRequestRecord

/** Failure with partial timings if available. */
@Serializable
@SerialName("RequestFailed")
data class RequestFailed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val errorKind: String,
    val message: String? = null,
    val timings: Timings = Timings(),
) : PerRequestRecord

/** Incremental Server-Sent Event payload emitted while streaming. */
@Serializable
@SerialName("ResponseStreamEvent")
data class ResponseStreamEvent(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val sequence: Long,
    val raw: String,
) : PerRequestRecord

/** Indicates the streaming response completed or terminated. */
@Serializable
@SerialName("ResponseStreamClosed")
data class ResponseStreamClosed(
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
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val url: String,
    val headers: List<Header> = emptyList(),
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketOpened")
data class WebSocketOpened(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val headers: List<Header> = emptyList(),
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketMessageSent")
data class WebSocketMessageSent(
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
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketClosed")
data class WebSocketClosed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketFailed")
data class WebSocketFailed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val errorKind: String,
    val message: String? = null,
) : PerWebSocketRecord

@Serializable
@SerialName("WebSocketCloseRequested")
data class WebSocketCloseRequested(
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

internal const val SCHEMA_VERSION: Int = 1

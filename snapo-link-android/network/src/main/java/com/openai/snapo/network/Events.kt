package com.openai.snapo.network

/**
 * Internal normalized network events used on-device before conversion to CDP.
 *
 * Wire/runtime payloads are CDP messages; export payloads are HAR.
 */
sealed interface NetworkEventRecord

data class Header(
    val name: String,
    val value: String,
)

sealed interface TimedRecord {
    val tWallMs: Long
    val tMonoNs: Long
}

/** Base for per-request events to let the desktop correlate rows. */
sealed interface PerRequestRecord : NetworkEventRecord, TimedRecord {
    val id: String
}

/** Request line + headers + tiny, already-redacted preview (if any). */
data class RequestWillBeSent(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val method: String,
    val url: String,
    val headers: List<Header> = emptyList(),
    val hasBody: Boolean = false,
    val body: String?,
    val bodyEncoding: String?,
    val bodyTruncatedBytes: Long?,
    val bodySize: Long?,
) : PerRequestRecord

/** Response line + headers + timing breakdown + body preview/full text (when available). */
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
data class RequestFailed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val errorKind: String,
    val message: String? = null,
    val timings: Timings = Timings(),
) : PerRequestRecord

/** Incremental Server-Sent Event payload emitted while streaming. */
data class ResponseStreamEvent(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val sequence: Long,
    val raw: String,
) : PerRequestRecord

/** Indicates the streaming response completed or terminated. */
data class ResponseStreamClosed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val reason: String,
    val message: String? = null,
    val totalEvents: Long,
    val totalBytes: Long,
) : PerRequestRecord

sealed interface PerWebSocketRecord : NetworkEventRecord, TimedRecord {
    val id: String
}

data class WebSocketWillOpen(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val url: String,
    val headers: List<Header> = emptyList(),
) : PerWebSocketRecord

data class WebSocketOpened(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val headers: List<Header> = emptyList(),
) : PerWebSocketRecord

data class WebSocketMessageSent(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val opcode: String,
    val preview: String? = null,
    val payloadSize: Long? = null,
    val enqueued: Boolean,
) : PerWebSocketRecord

data class WebSocketMessageReceived(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val opcode: String,
    val preview: String? = null,
    val payloadSize: Long? = null,
) : PerWebSocketRecord

data class WebSocketClosing(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
) : PerWebSocketRecord

data class WebSocketClosed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
) : PerWebSocketRecord

data class WebSocketFailed(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val errorKind: String,
    val message: String? = null,
) : PerWebSocketRecord

data class WebSocketCloseRequested(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
    val code: Int,
    val reason: String? = null,
    val initiated: String = "client",
    val accepted: Boolean,
) : PerWebSocketRecord

data class WebSocketCancelled(
    override val id: String,
    override val tWallMs: Long,
    override val tMonoNs: Long,
) : PerWebSocketRecord

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

internal fun NetworkEventRecord.perWebSocketRecord(): PerWebSocketRecord? = this as? PerWebSocketRecord

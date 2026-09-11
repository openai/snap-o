package com.openai.snapo.network

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds

class EventBufferEvictionTest {
    @Test
    fun `completed HTTP conversation is evicted when count limit is crossed`() {
        assertConversationEvictedAtCountLimit(httpConversation())
    }

    @Test
    fun `completed HTTP conversation is evicted when byte limit is crossed`() {
        assertConversationEvictedAtByteLimit(httpConversation())
    }

    @Test
    fun `completed response stream is evicted when count limit is crossed`() {
        assertConversationEvictedAtCountLimit(responseStreamConversation())
    }

    @Test
    fun `completed response stream is evicted when byte limit is crossed`() {
        assertConversationEvictedAtByteLimit(responseStreamConversation())
    }

    @Test
    fun `completed WebSocket conversation is evicted when count limit is crossed`() {
        assertConversationEvictedAtCountLimit(webSocketConversation())
    }

    @Test
    fun `completed WebSocket conversation is evicted when byte limit is crossed`() {
        assertConversationEvictedAtByteLimit(webSocketConversation())
    }

    @Test
    fun `late response body update is retrimmed to the byte limit`() {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedBytes = BYTE_LIMIT))
        httpConversation().forEach(buffer::append)

        val updated = buffer.updateLatestResponseBody(
            requestId = HTTP_ID,
            bodyPreview = "updated",
            body = "x".repeat(BYTE_LIMIT.toInt()),
            bodyEncoding = null,
            bodyTruncatedBytes = null,
            bodySize = BYTE_LIMIT,
        )

        assertEquals(true, updated)
        assertEquals(emptyList<NetworkEventRecord>(), buffer.snapshot())
        assertEquals(null, buffer.findResponseBody(HTTP_ID))
    }

    @Test
    fun `oldest incomplete request is evicted when count limit is crossed`() {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedEvents = 2))
        buffer.append(request(id = "first", wallTimeMs = 1L))
        buffer.append(request(id = "second", wallTimeMs = 2L))

        buffer.append(request(id = "third", wallTimeMs = 3L))

        assertEquals(listOf("second", "third"), buffer.snapshot().mapNotNull(::recordId))
    }

    @Test
    fun `oversized incomplete request evicts its retained body`() {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedBytes = BYTE_LIMIT))

        buffer.append(
            request(
                id = HTTP_ID,
                wallTimeMs = 1L,
                body = "x".repeat(BYTE_LIMIT.toInt()),
            ),
        )

        assertEquals(emptyList<NetworkEventRecord>(), buffer.snapshot())
        assertEquals(null, buffer.findRequestBody(HTTP_ID))
    }

    @Test
    fun `active response stream is evicted whole and clears active state`() {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedEvents = 3))
        activeResponseStreamConversation().forEach(buffer::append)

        assertEquals(emptyList<NetworkEventRecord>(), buffer.snapshot())

        buffer.append(request(id = STREAM_ID, wallTimeMs = 10L))
        buffer.append(response(id = STREAM_ID, wallTimeMs = 11L))
        buffer.append(responseFinished(id = "sentinel-1", wallTimeMs = 12L))
        buffer.append(responseFinished(id = "sentinel-2", wallTimeMs = 13L))

        assertEquals(
            listOf(STREAM_ID, STREAM_ID, "sentinel-2"),
            buffer.snapshot().mapNotNull(::recordId),
        )
    }

    @Test
    fun `open WebSocket is evicted whole and clears open state`() {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedEvents = 3))
        openWebSocketConversation().forEach(buffer::append)

        assertEquals(emptyList<NetworkEventRecord>(), buffer.snapshot())

        buffer.append(webSocketMessage(id = WEB_SOCKET_ID, wallTimeMs = 10L))
        buffer.append(request(id = HTTP_ID, wallTimeMs = 11L))
        buffer.append(response(id = HTTP_ID, wallTimeMs = 12L))
        buffer.append(responseFinished(id = SENTINEL_ID, wallTimeMs = 13L))

        assertEquals(
            listOf(HTTP_ID, HTTP_ID, SENTINEL_ID),
            buffer.snapshot().mapNotNull(::recordId),
        )
    }

    @Test
    fun `completed conversation is preferred over an older active conversation`() {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedEvents = 6))
        activeResponseStreamConversation().dropLast(1).forEach(buffer::append)
        httpConversation(wallTimeOffsetMs = 10L).forEach(buffer::append)

        buffer.append(responseFinished(id = SENTINEL_ID, wallTimeMs = 20L))

        assertEquals(
            listOf(STREAM_ID, STREAM_ID, STREAM_ID, SENTINEL_ID),
            buffer.snapshot().mapNotNull(::recordId),
        )
    }

    @Test
    fun `response headers alone do not mark a conversation complete`() {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedEvents = 5))
        buffer.append(request(id = "active", wallTimeMs = 1L))
        buffer.append(response(id = "active", wallTimeMs = 2L))
        httpConversation(wallTimeOffsetMs = 10L).forEach(buffer::append)

        buffer.append(responseFinished(id = SENTINEL_ID, wallTimeMs = 20L))

        assertEquals(
            listOf("active", "active", SENTINEL_ID),
            buffer.snapshot().mapNotNull(::recordId),
        )
    }

    @Test
    fun `expiring the last response stream record clears active state`() {
        val buffer = EventBuffer(
            NetworkInspectorConfig(
                bufferWindow = 5.milliseconds,
                maxBufferedEvents = 3,
            ),
        )
        activeResponseStreamConversation().dropLast(1).forEach(buffer::append)

        buffer.append(webSocketWillOpen(id = TRIGGER_ID, wallTimeMs = 10L))

        assertEquals(listOf(TRIGGER_ID), buffer.snapshot().mapNotNull(::recordId))

        buffer.append(request(id = STREAM_ID, wallTimeMs = 11L))
        buffer.append(response(id = STREAM_ID, wallTimeMs = 12L))
        buffer.append(webSocketMessage(id = TRIGGER_ID, wallTimeMs = 13L))

        assertEquals(
            listOf(STREAM_ID, STREAM_ID),
            buffer.snapshot().mapNotNull(::recordId),
        )
    }

    @Test
    fun `partial expiry keeps WebSocket open state`() {
        val buffer = EventBuffer(
            NetworkInspectorConfig(
                bufferWindow = 5.milliseconds,
                maxBufferedEvents = 5,
            ),
        )
        buffer.append(webSocketWillOpen(id = WEB_SOCKET_ID, wallTimeMs = 1L))
        buffer.append(
            WebSocketOpened(
                id = WEB_SOCKET_ID,
                tWallMs = 7L,
                tMonoNs = 7L,
                code = 101,
            ),
        )
        buffer.append(webSocketMessage(id = WEB_SOCKET_ID, wallTimeMs = 8L))
        httpConversation(wallTimeOffsetMs = 8L).forEach(buffer::append)

        buffer.append(webSocketMessage(id = WEB_SOCKET_ID, wallTimeMs = 12L))

        assertEquals(
            listOf(WEB_SOCKET_ID, WEB_SOCKET_ID, WEB_SOCKET_ID),
            buffer.snapshot().mapNotNull(::recordId),
        )
    }

    private fun assertConversationEvictedAtCountLimit(
        conversation: List<NetworkEventRecord>,
    ) {
        val buffer = EventBuffer(
            NetworkInspectorConfig(maxBufferedEvents = conversation.size),
        )
        conversation.forEach(buffer::append)

        assertEquals(conversation.size, buffer.snapshot().size)

        buffer.append(responseFinished(id = SENTINEL_ID, wallTimeMs = 100L))

        assertEquals(listOf(SENTINEL_ID), buffer.snapshot().mapNotNull(::recordId))
    }

    private fun assertConversationEvictedAtByteLimit(
        conversation: List<NetworkEventRecord>,
    ) {
        val buffer = EventBuffer(
            NetworkInspectorConfig(maxBufferedBytes = BYTE_LIMIT),
        )
        conversation.forEach(buffer::append)

        assertEquals(conversation.size, buffer.snapshot().size)

        buffer.append(
            WebSocketMessageReceived(
                id = SENTINEL_ID,
                tWallMs = 100L,
                tMonoNs = 100L,
                opcode = "text",
                preview = "x".repeat(300),
            ),
        )

        assertEquals(listOf(SENTINEL_ID), buffer.snapshot().mapNotNull(::recordId))
    }

    private fun httpConversation(wallTimeOffsetMs: Long = 0L): List<NetworkEventRecord> = listOf(
        request(id = HTTP_ID, wallTimeMs = wallTimeOffsetMs + 1L),
        response(id = HTTP_ID, wallTimeMs = wallTimeOffsetMs + 2L),
        responseFinished(id = HTTP_ID, wallTimeMs = wallTimeOffsetMs + 3L),
    )

    private fun activeResponseStreamConversation(): List<NetworkEventRecord> = listOf(
        request(id = STREAM_ID, wallTimeMs = 1L),
        response(id = STREAM_ID, wallTimeMs = 2L),
        responseStreamEvent(id = STREAM_ID, wallTimeMs = 3L),
        responseStreamEvent(id = STREAM_ID, wallTimeMs = 4L),
    )

    private fun responseStreamConversation(): List<NetworkEventRecord> = listOf(
        request(id = STREAM_ID, wallTimeMs = 1L),
        response(id = STREAM_ID, wallTimeMs = 2L),
        ResponseStreamEvent(
            id = STREAM_ID,
            tWallMs = 3L,
            tMonoNs = 3L,
            sequence = 1L,
            raw = "x".repeat(100),
        ),
        ResponseStreamClosed(
            id = STREAM_ID,
            tWallMs = 4L,
            tMonoNs = 4L,
            reason = "completed",
            totalEvents = 1L,
            totalBytes = 100L,
        ),
    )

    private fun webSocketConversation(): List<NetworkEventRecord> = listOf(
        WebSocketWillOpen(
            id = WEB_SOCKET_ID,
            tWallMs = 1L,
            tMonoNs = 1L,
            url = "wss://example.com/socket",
        ),
        WebSocketOpened(
            id = WEB_SOCKET_ID,
            tWallMs = 2L,
            tMonoNs = 2L,
            code = 101,
        ),
        WebSocketMessageReceived(
            id = WEB_SOCKET_ID,
            tWallMs = 3L,
            tMonoNs = 3L,
            opcode = "text",
            preview = "received message",
        ),
        WebSocketClosed(
            id = WEB_SOCKET_ID,
            tWallMs = 4L,
            tMonoNs = 4L,
            code = 1000,
        ),
    )

    private fun openWebSocketConversation(): List<NetworkEventRecord> = listOf(
        webSocketWillOpen(id = WEB_SOCKET_ID, wallTimeMs = 1L),
        WebSocketOpened(
            id = WEB_SOCKET_ID,
            tWallMs = 2L,
            tMonoNs = 2L,
            code = 101,
        ),
        webSocketMessage(id = WEB_SOCKET_ID, wallTimeMs = 3L),
        webSocketMessage(id = WEB_SOCKET_ID, wallTimeMs = 4L),
    )

    private fun webSocketWillOpen(id: String, wallTimeMs: Long): WebSocketWillOpen =
        WebSocketWillOpen(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs,
            url = "wss://example.com/socket",
        )

    private fun request(
        id: String,
        wallTimeMs: Long,
        body: String? = null,
    ): RequestWillBeSent =
        RequestWillBeSent(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs,
            method = "GET",
            url = "https://example.com/$id",
            body = body,
            bodyEncoding = null,
            bodyTruncatedBytes = null,
            bodySize = body?.length?.toLong(),
        )

    private fun response(id: String, wallTimeMs: Long): ResponseReceived =
        ResponseReceived(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs,
            code = 200,
        )

    private fun responseFinished(id: String, wallTimeMs: Long): ResponseFinished =
        ResponseFinished(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs,
        )

    private fun responseStreamEvent(id: String, wallTimeMs: Long): ResponseStreamEvent =
        ResponseStreamEvent(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs,
            sequence = wallTimeMs,
            raw = "data: $wallTimeMs",
        )

    private fun webSocketMessage(id: String, wallTimeMs: Long): WebSocketMessageReceived =
        WebSocketMessageReceived(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs,
            opcode = "text",
            preview = "message $wallTimeMs",
        )

    private fun recordId(record: NetworkEventRecord): String? = when (record) {
        is PerRequestRecord -> record.id
        is PerWebSocketRecord -> record.id
    }

    private companion object {
        const val BYTE_LIMIT = 500L
        const val HTTP_ID = "http"
        const val STREAM_ID = "stream"
        const val WEB_SOCKET_ID = "web-socket"
        const val SENTINEL_ID = "sentinel"
        const val TRIGGER_ID = "trigger"
    }
}

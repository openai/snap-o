package com.openai.snapo.network

import org.junit.Assert.assertEquals
import org.junit.Test

class EventBufferSequenceTest {
    @Test
    fun `sequence follows publication order independently of event time`() {
        val buffer = EventBuffer(NetworkInspectorConfig())
        val firstSequence = buffer.append(request(id = "first", wallTimeMs = 200L))
        val secondSequence = buffer.append(request(id = "second", wallTimeMs = 100L))

        val snapshot = buffer.sequencedSnapshot()

        assertEquals(1L, firstSequence)
        assertEquals(2L, secondSequence)
        assertEquals(2L, snapshot.watermark)
        assertEquals(
            mapOf("first" to 1L, "second" to 2L),
            snapshot.records.associate { event ->
                (event.record as RequestWillBeSent).id to event.snapoSequence
            },
        )
    }

    @Test
    fun `response body updates preserve the event sequence`() {
        val buffer = EventBuffer(NetworkInspectorConfig())
        val sequence = buffer.append(
            ResponseReceived(
                id = "request",
                tWallMs = 100L,
                tMonoNs = 10L,
                code = 200,
            ),
        )

        buffer.updateLatestResponseBody(
            requestId = "request",
            bodyPreview = "updated",
            body = "updated body",
            bodyEncoding = null,
            bodyTruncatedBytes = null,
            bodySize = 12L,
        )

        val event = buffer.sequencedSnapshot().records.single()
        assertEquals(sequence, event.snapoSequence)
        assertEquals("updated", (event.record as ResponseReceived).bodyPreview)
    }

    @Test
    fun `request body updates preserve the event sequence`() {
        val buffer = EventBuffer(NetworkInspectorConfig())
        val sequence = buffer.append(request(id = "request", wallTimeMs = 100L))

        buffer.updateLatestRequestBody(
            requestId = "request",
            body = "updated body",
            bodyEncoding = null,
            bodyTruncatedBytes = 2L,
            bodySize = 14L,
        )

        val event = buffer.sequencedSnapshot().records.single()
        assertEquals(sequence, event.snapoSequence)
        assertEquals(14L, (event.record as RequestWillBeSent).bodySize)
        assertEquals("updated body", buffer.findRequestBody("request")?.body)
    }

    @Test
    fun `watermark advances when older events are evicted`() {
        val buffer = EventBuffer(
            NetworkInspectorConfig(maxBufferedEvents = 1),
        )
        buffer.append(finishedRequest(id = "first", wallTimeMs = 100L))
        buffer.append(finishedRequest(id = "second", wallTimeMs = 200L))

        val snapshot = buffer.sequencedSnapshot()

        assertEquals(2L, snapshot.watermark)
        assertEquals(listOf(2L), snapshot.records.map(SequencedNetworkEvent::snapoSequence))
    }

    private fun request(id: String, wallTimeMs: Long): RequestWillBeSent =
        RequestWillBeSent(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs * 1_000_000L,
            method = "GET",
            url = "https://example.com/$id",
            body = null,
            bodyEncoding = null,
            bodyTruncatedBytes = null,
            bodySize = null,
        )

    private fun finishedRequest(id: String, wallTimeMs: Long): ResponseFinished =
        ResponseFinished(
            id = id,
            tWallMs = wallTimeMs,
            tMonoNs = wallTimeMs * 1_000_000L,
        )
}

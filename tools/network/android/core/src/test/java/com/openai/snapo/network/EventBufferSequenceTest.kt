package com.openai.snapo.network

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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
        assertEquals(
            mapOf("first" to 1L, "second" to 2L),
            snapshot.associate { event ->
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

        val event = buffer.sequencedSnapshot().single()
        assertEquals(sequence, event.snapoSequence)
        assertEquals("updated", (event.record as ResponseReceived).bodyPreview)
    }

    @Test
    fun `upload completion has a fresh sequence and is searchable before a response`() = runBlocking {
        val buffer = EventBuffer(NetworkInspectorConfig())
        val sequence = buffer.append(request(id = "request", wallTimeMs = 100L).copy(hasBody = true))
        val before = searchBodies(buffer.bodySearchSnapshot(listOf("request")), listOf("needle"))
        assertFalse(before.results.single().request.complete)
        assertTrue(before.results.single().request.terms.isEmpty())

        val update = buffer.updateLatestRequestBody(
            requestId = "request",
            body = "needle",
            bodyEncoding = null,
            bodyTruncatedBytes = 0L,
            bodySize = 6L,
        )!!

        assertEquals(sequence + 1, update.snapoSequence)
        assertEquals(update, buffer.sequencedSnapshot().single())
        assertEquals(null, (update.record as RequestWillBeSent).body)
        val after = searchBodies(buffer.bodySearchSnapshot(listOf("request")), listOf("needle"))
        assertTrue(after.results.single().request.complete)
        assertEquals(listOf("needle"), after.results.single().request.terms)
        assertFalse(after.results.single().response.complete)
        assertEquals(update.snapoSequence + 1, buffer.append(finishedRequest("request", 200L)))
    }

    @Test
    fun `retained events keep their sequence after eviction`() {
        val buffer = EventBuffer(
            NetworkInspectorConfig(maxBufferedEvents = 1),
        )
        buffer.append(finishedRequest(id = "first", wallTimeMs = 100L))
        buffer.append(finishedRequest(id = "second", wallTimeMs = 200L))

        val snapshot = buffer.sequencedSnapshot()

        assertEquals(listOf(2L), snapshot.map(SequencedNetworkEvent::snapoSequence))
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

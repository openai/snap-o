package com.openai.snapo.network

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BodySearchTest {
    @Test
    fun `reports request and response matches and missing bodies`() = runBlocking {
        val result = searchBodies(
            listOf(
                SearchableRequest(
                    "one",
                    SearchableBody(CapturedBody("CLIENT token", null), BodyCoverage.Complete),
                    SearchableBody(CapturedBody("server tbo token", null), BodyCoverage.Incomplete),
                ),
                SearchableRequest(
                    "missing",
                    SearchableBody(null, BodyCoverage.Incomplete),
                    SearchableBody(null, BodyCoverage.Absent)
                ),
            ),
            listOf("client", "tbo", "missing"),
        )
        assertEquals(listOf("client"), result.results[0].request.terms)
        assertEquals(listOf("tbo"), result.results[0].response.terms)
        assertTrue(result.results[0].request.complete)
        assertFalse(result.results[0].response.complete)
        assertEquals("server tbo token", result.results[0].response.snippet)
        assertFalse(result.results[1].request.complete)
        assertTrue(result.results[1].response.complete)
    }

    @Test
    fun `does not search binary base64 as text`() = runBlocking {
        val result = searchResponse(SearchableBody(CapturedBody("dGJv", "base64"), BodyCoverage.Complete), "dGJv")
        assertTrue(result.terms.isEmpty())
        assertFalse(result.complete)
    }

    @Test
    fun `response includes empty matches and marks partial searches`() {
        val json = ProtocolJson.encodeToString(BodySearchMatch.serializer(), BodySearchMatch(emptyList(), false))
        assertTrue(json.contains("\"terms\":[]"))
        assertTrue(json.contains("\"complete\":false"))
    }

    @Test
    fun `searches gzip using the declared charset`() = runBlocking {
        listOf("UTF-8", "ISO-8859-1").forEach { charset ->
            val bytes = "café".toByteArray(java.nio.charset.Charset.forName(charset))
            val output = java.io.ByteArrayOutputStream()
            java.util.zip.GZIPOutputStream(output).use { it.write(bytes) }
            val buffer = EventBuffer(NetworkInspectorConfig())
            buffer.append(
                request(kotlin.io.encoding.Base64.encode(output.toByteArray())).copy(
                    headers = listOf(
                        Header("Content-Encoding", "gzip"),
                        Header("Content-Type", "text/plain; charset=$charset")
                    ),
                    bodyEncoding = "base64",
                )
            )
            val result = searchBodies(buffer.bodySearchSnapshot(listOf("one")), listOf("café")).results.single().request
            assertEquals(listOf("café"), result.terms)
            assertTrue(result.complete)
        }
    }

    @Test
    fun `keeps a copy after the cache removes the body`() = runBlocking {
        val buffer = EventBuffer(NetworkInspectorConfig(maxBufferedEvents = 1))
        buffer.append(ResponseReceived(id = "old", tWallMs = 1L, tMonoNs = 1L, code = 200, body = "retained needle"))
        val snapshot = buffer.bodySearchSnapshot(listOf("old"))
        buffer.append(ResponseReceived(id = "new", tWallMs = 2L, tMonoNs = 2L, code = 200))
        assertEquals(listOf("needle"), searchBodies(snapshot, listOf("needle")).results.single().response.terms)
        val evicted = searchBodies(buffer.bodySearchSnapshot(listOf("old")), listOf("needle")).results.single()
        assertTrue(evicted.response.terms.isEmpty())
        assertFalse(evicted.response.complete)
    }

    @Test
    fun `parses gzip aliases and header lists consistently`() {
        listOf("gzip", "x-gzip", " X-GZip ; level=1", "identity, x-gzip", "identity\nx-gzip").forEach {
            assertTrue(hasGzipContentEncoding(listOf(Header("Content-Encoding", it))))
        }
        assertFalse(hasGzipContentEncoding(listOf(Header("Content-Encoding", "br"))))
    }

    @Test
    fun `request completeness requires explicit zero truncation`() = runBlocking {
        listOf(null, 0L, 4L).forEach { truncated ->
            val event = request("éééééé").copy(bodyTruncatedBytes = truncated, bodySize = 10L)
            val message = event.toCdpMessage(null)
            val params = ProtocolJson.decodeFromJsonElement(CdpRequestWillBeSentParams.serializer(), message.params!!)
            assertEquals(truncated, params.request.postDataTruncatedBytes)
            val buffer = EventBuffer(NetworkInspectorConfig())
            buffer.append(event)
            val match = searchBodies(buffer.bodySearchSnapshot(listOf("one")), listOf("missing")).results.single()
            assertEquals(truncated == 0L, match.request.complete)
        }
    }

    @Test
    fun `missing and contradictory body metadata stays incomplete`() {
        assertEquals(BodyCoverage.Absent, requestBodyCoverage(false, false, null))
        assertEquals(BodyCoverage.Incomplete, requestBodyCoverage(false, null, null))
        assertEquals(BodyCoverage.Incomplete, requestBodyCoverage(false, true, 0))
        assertEquals(BodyCoverage.Incomplete, requestBodyCoverage(true, false, null))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `limits requests per search`() {
        BodySearchQuery(List(65) { "$it" }, listOf("tbo")).validate()
    }

    private fun request(body: String) = RequestWillBeSent(
        id = "one", tWallMs = 1L, tMonoNs = 1L, method = "POST", url = "https://example.test/",
        hasBody = true, body = body, bodyEncoding = null, bodyTruncatedBytes = 0, bodySize = null,
    )

    private suspend fun searchResponse(body: SearchableBody, term: String) = searchBodies(
        listOf(SearchableRequest("one", SearchableBody(null, BodyCoverage.Absent), body)),
        listOf(term),
    ).results.single().response
}

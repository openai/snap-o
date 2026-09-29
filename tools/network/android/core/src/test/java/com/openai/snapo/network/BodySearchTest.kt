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
                    SearchableBody(CapturedBody("CLIENT token", null), true),
                    SearchableBody(CapturedBody("server tbo token", null), false),
                ),
                SearchableRequest("missing", SearchableBody(null, false), SearchableBody(null, true)),
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
        val result = searchBodies(
            listOf(
                SearchableRequest(
                    "binary",
                    SearchableBody(null, true),
                    SearchableBody(CapturedBody("dGJv", "base64"), true)
                )
            ),
            listOf("dGJv"),
        ).results.single().response
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
    fun `searches gzip text and keeps a copy after the cache removes the body`() = runBlocking {
        val output = java.io.ByteArrayOutputStream()
        java.util.zip.GZIPOutputStream(output).use { it.write("compressed needle".toByteArray()) }
        val encoded = kotlin.io.encoding.Base64.encode(output.toByteArray())
        val gzip =
            searchBodies(
                listOf(
                    SearchableRequest(
                        "gzip",
                        SearchableBody(CapturedBody(encoded, "base64"), true, true),
                        SearchableBody(null, true)
                    )
                ),
                listOf("needle")
            )
        assertEquals(listOf("needle"), gzip.results.single().request.terms)
        assertTrue(gzip.results.single().request.complete)

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
    fun `request events carry explicit truncation metadata`() {
        listOf(null, 0L, 4L).forEach { truncated ->
            val event = RequestWillBeSent(
                id = "one", tWallMs = 1L, tMonoNs = 1L, method = "POST",
                url = "https://example.test/", hasBody = true, body = "éééééé",
                bodyEncoding = null, bodyTruncatedBytes = truncated, bodySize = 10L,
            )
            val message = event.toCdpMessage(null)
            val params = ProtocolJson.decodeFromJsonElement(CdpRequestWillBeSentParams.serializer(), message.params!!)
            assertEquals(truncated, params.request.postDataTruncatedBytes)
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun `limits requests per search`() {
        BodySearchQuery(List(65) { "$it" }, listOf("tbo")).validate()
    }
}

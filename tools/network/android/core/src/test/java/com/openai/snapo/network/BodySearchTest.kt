package com.openai.snapo.network

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BodySearchTest {
    @Test
    fun `reports matches and missing bodies`() = runBlocking {
        val full = SearchableBody(CapturedBody("CLIENT token", null), BodyCoverage.Complete)
        val partial = SearchableBody(CapturedBody("server tbo token", null), BodyCoverage.Incomplete)
        val result = searchBodies(listOf(SearchableRequest("one", full, partial)), listOf("client", "tbo", "missing"))
        assertEquals(BodySearchMatch(listOf("client"), true, "CLIENT token"), result.results.single().request)
        assertEquals(BodySearchMatch(listOf("tbo"), false, "server tbo token"), result.results.single().response)
        for ((source, complete) in listOf(
            SearchableBody(null, BodyCoverage.Incomplete) to false,
            SearchableBody(null, BodyCoverage.Absent) to true,
            SearchableBody(CapturedBody("dGJv", "base64"), BodyCoverage.Complete) to false,
        )) {
            assertEquals(BodySearchMatch(emptyList(), complete), searchResponse(source, "dGJv"))
        }
    }

    @Test
    fun `searches gzip using the declared charset`() = runBlocking {
        listOf(
            "gzip" to "UTF-8",
            "x-gzip" to "ISO-8859-1",
            " X-GZip ; level=1" to "UTF-8",
            "identity, x-gzip" to "ISO-8859-1",
            "identity\nx-gzip" to "UTF-8"
        ).forEach { (encoding, charset) ->
            val bytes = "café".toByteArray(java.nio.charset.Charset.forName(charset))
            val output = java.io.ByteArrayOutputStream()
            java.util.zip.GZIPOutputStream(output).use { it.write(bytes) }
            val buffer = EventBuffer(NetworkInspectorConfig())
            buffer.append(
                request(kotlin.io.encoding.Base64.encode(output.toByteArray())).copy(
                    headers = listOf(
                        Header("Content-Encoding", encoding),
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
    fun `response coverage follows the request lifecycle`() = runBlocking {
        val response = ResponseReceived(id = "one", tWallMs = 2, tMonoNs = 2, code = 200)
        val failed = RequestFailed(id = "one", tWallMs = 3, tMonoNs = 3, errorKind = "io")
        val end = ResponseFinished(id = "one", tWallMs = 3, tMonoNs = 3)
        val scenarios = listOf(
            emptyList<NetworkEventRecord>() to false,
            listOf(failed) to true,
            listOf(response, failed) to false,
            listOf(response.copy(body = "prefix"), failed) to false,
            listOf(response.copy(body = "full"), end) to true,
            listOf(response.copy(body = "prefix"), end.copy(bodyTruncatedBytes = 4)) to false,
        )
        for ((events, complete) in scenarios) {
            val buffer = EventBuffer(NetworkInspectorConfig())
            buffer.append(request("").copy(hasBody = false, body = null))
            events.forEach(buffer::append)
            val match = searchBodies(buffer.bodySearchSnapshot(listOf("one")), listOf("missing")).results.single()
            assertEquals(events.toString(), complete, match.response.complete)
        }
    }

    @Test
    fun `unicode matching keeps source offsets for snippets`() = runBlocking {
        val text = "İ".repeat(100) + "abc" + "x".repeat(200)
        assertEquals(100, TextMatcher(text).find("abc"))
        val match = searchResponse(SearchableBody(CapturedBody(text, null), BodyCoverage.Complete), "abc")
        assertEquals(listOf("abc"), match.terms)
        assertTrue(match.snippet!!.contains("abc"))
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

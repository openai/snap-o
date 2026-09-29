package com.openai.snapo.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import kotlinx.serialization.Serializable
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale
import java.util.zip.GZIPInputStream
import kotlin.coroutines.coroutineContext
import kotlin.io.encoding.Base64

@Serializable
internal data class BodySearchQuery(val requestIds: List<String>, val terms: List<String>) {
    fun validate() {
        require(requestIds.size in 1..64 && requestIds.distinct().size == requestIds.size)
        require(requestIds.all { it.length in 1..512 })
        require(terms.size in 1..64 && terms.all { it.length in 1..256 })
    }
}

@Serializable
internal data class BodySearchMatch(
    val terms: List<String>,
    val complete: Boolean,
    val snippet: String? = null,
)

@Serializable
internal data class RequestBodySearchMatch(
    val requestId: String,
    val request: BodySearchMatch,
    val response: BodySearchMatch,
)

@Serializable
internal data class BodySearchReply(val results: List<RequestBodySearchMatch>)

internal data class SearchableBody(
    val body: CapturedBody?,
    val complete: Boolean,
    val gzip: Boolean = false,
)

internal data class SearchableRequest(
    val requestId: String,
    val request: SearchableBody,
    val response: SearchableBody,
)

// Search a fixed copy on a background thread without holding the capture lock.
internal suspend fun searchBodies(snapshot: List<SearchableRequest>, terms: List<String>): BodySearchReply =
    withContext(Dispatchers.Default) {
        val normalized = terms.map { it.lowercase(Locale.ROOT) }.distinct()
        BodySearchReply(
            snapshot.map { entry ->
                coroutineContext.ensureActive()
                RequestBodySearchMatch(
                    entry.requestId,
                    searchBody(entry.request, normalized),
                    searchBody(entry.response, normalized)
                )
            }
        )
    }

private const val MaxSearchCharacters = 8 * 1024 * 1024

private suspend fun searchBody(source: SearchableBody, terms: List<String>): BodySearchMatch {
    val captured = source.body ?: return BodySearchMatch(emptyList(), source.complete)
    val decoded = decodeSearchBody(captured, source.gzip) ?: return BodySearchMatch(emptyList(), false)
    val text = decoded.take(MaxSearchCharacters)
    val normalized = text.lowercase(Locale.ROOT)
    val matches = mutableListOf<String>()
    var firstOffset = -1
    for (term in terms) {
        yield()
        val offset = normalized.indexOf(term)
        if (offset >= 0) {
            matches.add(term)
            if (firstOffset < 0) firstOffset = offset
        }
    }
    return BodySearchMatch(
        terms = matches,
        complete = source.complete && decoded.length <= MaxSearchCharacters,
        snippet = if (firstOffset < 0) {
            null
        } else {
            text.substring(
                (firstOffset - 40).coerceIn(0, text.length),
                (firstOffset + 120).coerceAtMost(text.length),
            )
        },
    )
}

private fun decodeSearchBody(body: CapturedBody, gzip: Boolean): String? {
    if (!body.encoding.equals("base64", true)) return body.body
    if (!gzip || body.body.length > MaxSearchCharacters * 2) return null
    return runCatching {
        val bytes = Base64.decode(body.body)
        val decoded = GZIPInputStream(ByteArrayInputStream(bytes)).use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (output.size() <= MaxSearchCharacters) {
                val count = stream.read(buffer)
                if (count < 0) break
                output.write(buffer, 0, count)
            }
            if (output.size() > MaxSearchCharacters) return null
            output.toByteArray()
        }
        Charsets.UTF_8.newDecoder().onMalformedInput(
            CodingErrorAction.REPORT
        ).decode(ByteBuffer.wrap(decoded)).toString()
    }.getOrNull()
}

internal fun hasGzipContentEncoding(headers: List<Header>): Boolean = headers
    .filter { it.name.equals("content-encoding", true) }
    .flatMap { it.value.split(',', '\n') }
    .any { it.substringBefore(';').trim().lowercase(Locale.ROOT) in listOf("gzip", "x-gzip") }

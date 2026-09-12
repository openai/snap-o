package com.openai.snapo.tool

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.CharacterCodingException

/** Limits and accepted request forms for a tool plugin's endpoints. */
data class ToolHttpRequestPolicy(
    val maxBodyBytes: Int = 64 * 1024,
    val bodyMethods: Set<String> = setOf("POST", "PUT", "PATCH"),
    val httpVersions: Set<String> = setOf("HTTP/1.1"),
    val requireJsonContentType: Boolean = true,
) {
    init {
        require(maxBodyBytes >= 0)
    }
}

data class ToolHttpRequest(
    val method: String,
    val requestTarget: String,
    val headers: Map<String, String>,
    val body: ByteArray = byteArrayOf(),
) {
    init {
        require(requestTarget.startsWith('/') && '#' !in requestTarget) { "Expected a relative request target" }
        URI.create(requestTarget) // Reject malformed escapes before routing or decoding parameters.
    }

    /** Encoded path without the query. Decode individual route parameters instead of path separators. */
    val path: String get() = requestTarget.substringBefore('?')

    val queryParameters: Map<String, List<String>> by lazy {
        requestTarget.substringAfter('?', "").split('&').filter(String::isNotEmpty).groupBy(
            { URLDecoder.decode(it.substringBefore('='), "UTF-8") },
            { URLDecoder.decode(it.substringAfter('=', ""), "UTF-8") },
        )
    }

    fun bodyText(): String = try {
        body.decodeToString(throwOnInvalidSequence = true)
    } catch (error: CharacterCodingException) {
        throw ToolHttpException(400, "Request body must be UTF-8", error)
    }

    companion object {
        fun read(
            input: InputStream,
            policy: ToolHttpRequestPolicy = ToolHttpRequestPolicy(),
        ): ToolHttpRequest {
            val lines = readHead(input).removeSuffix("\r\n\r\n").split("\r\n")
            val first = lines.first().split(' ')
            require(first.size == 3 && first[2] in policy.httpVersions) { "Unsupported HTTP request line" }
            require(first[1].startsWith('/') && !first[1].contains('#')) { "Expected a relative request path" }
            val headers = parseHeaders(lines.drop(1))
            ToolBrowserAccess.origin(headers)
            val length = bodyLength(first[0], headers, policy)
            val body = ByteArray(length)
            var offset = 0
            while (offset < body.size) {
                val count = input.read(body, offset, body.size - offset)
                if (count < 0) throw EOFException("HTTP request body ended early")
                offset += count
            }
            return ToolHttpRequest(first[0], first[1], headers, body)
        }

        private fun readHead(input: InputStream): String {
            val bytes = ByteArrayOutputStream()
            var delimiter = 0
            var hasRequestLine = false
            while (bytes.size() < MaxHttpHeaderBytes) {
                val value = input.read()
                if (value < 0) throw EOFException("HTTP request ended before its headers")
                require(value < 128) { "HTTP headers must use ASCII" }
                bytes.write(value)
                delimiter = (delimiter shl 8) or value
                if (!hasRequestLine) {
                    require(bytes.size() <= 4 * 1024) { "HTTP request line is too large" }
                    hasRequestLine = delimiter and 0xffff == 0x0d0a
                }
                if (delimiter == 0x0d0a0d0a) return bytes.toString(Charsets.US_ASCII.name())
            }
            throw ToolHttpException(400, "HTTP headers are too large")
        }

        private fun parseHeaders(lines: List<String>): Map<String, String> {
            val headers = mutableMapOf<String, String>()
            for (line in lines) {
                val colon = line.indexOf(':')
                require(colon > 0) { "Malformed HTTP header" }
                val name = line.take(colon).lowercase()
                require(HeaderName.matches(name) && name !in headers) { "Duplicate or invalid HTTP header" }
                val value = line.drop(colon + 1).trim()
                require(value.none { it.code < 32 && it != '\t' || it.code == 127 }) { "Invalid HTTP header value" }
                headers[name] = value
            }
            return headers
        }

        private fun bodyLength(
            method: String,
            headers: Map<String, String>,
            policy: ToolHttpRequestPolicy,
        ): Int {
            require(headers["transfer-encoding"] == null) { "Chunked request bodies are not supported" }
            val rawLength = headers["content-length"] ?: "0"
            val length = rawLength.toIntOrNull()
            require(rawLength.all { it in '0'..'9' } && length != null && length >= 0) { "Invalid Content-Length" }
            if (length > policy.maxBodyBytes) throw ToolHttpException(413, "The request body is too large")
            require(method in policy.bodyMethods || length == 0) { "This method cannot have a body" }
            if (length > 0 && policy.requireJsonContentType) {
                require(headers["content-type"]?.substringBefore(';')?.trim().equals("application/json", true)) {
                    "Request bodies must use application/json"
                }
            }
            return length
        }
    }
}

class ToolHttpException(
    val statusCode: Int,
    override val message: String,
    cause: Throwable? = null,
    val allowedMethods: String? = null,
) : IllegalArgumentException(message, cause)

private const val MaxHttpHeaderBytes = 16 * 1024
private val HeaderName = Regex("[!#$%&'*+.^_`|~0-9a-z-]+")

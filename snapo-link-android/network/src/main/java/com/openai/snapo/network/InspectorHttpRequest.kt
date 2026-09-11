package com.openai.snapo.network

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.URI
import java.nio.charset.StandardCharsets

internal data class InspectorHttpRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String>,
    val body: ByteArray = byteArrayOf(),
) {
    companion object {
        fun read(input: InputStream): InspectorHttpRequest {
            val request = parse(readHead(input))
            val body = ByteArray(request.headers["content-length"]?.toIntOrNull() ?: 0)
            var offset = 0
            while (offset < body.size) {
                val count = input.read(body, offset, body.size - offset)
                if (count < 0) throw EOFException("HTTP request body ended early")
                offset += count
            }
            return request.copy(body = body)
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
                if (delimiter == 0x0d0a0d0a) return String(bytes.toByteArray(), StandardCharsets.US_ASCII)
            }
            throw IOException("HTTP headers exceed $MaxHttpHeaderBytes bytes")
        }

        private fun parse(head: String): InspectorHttpRequest {
            val lines = head.removeSuffix("\r\n\r\n").split("\r\n")
            val first = lines.first().split(' ')
            require(first.size == 3 && first[2] == "HTTP/1.1") { "Expected an HTTP/1.1 request" }
            require(first[1].startsWith('/') && !first[1].contains('#')) { "Expected a relative request path" }
            val headers = parseHeaders(lines.drop(1))
            validateOrigin(headers)
            validateBody(first[0], headers)
            return InspectorHttpRequest(first[0], first[1], headers)
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

        private fun validateOrigin(headers: Map<String, String>) {
            val host = requireNotNull(headers["host"]) { "Missing Host header" }
            val authority = runCatching { URI("http://$host") }.getOrNull()
            // Origin can be absent on same-origin GETs. Check Host to prevent DNS rebinding.
            require(
                authority?.host?.lowercase() in BrowserHosts && authority?.rawAuthority == host &&
                    authority.rawUserInfo == null
            ) {
                "Invalid Host header"
            }
            headers["origin"]?.let { value ->
                val origin = runCatching { URI(value) }.getOrNull()
                require(
                    (
                        InspectorOrigin.matches(value) ||
                            (origin?.scheme in listOf("http", "https") && origin?.host?.lowercase() in BrowserHosts)
                        ) &&
                        origin?.rawUserInfo == null && origin?.rawQuery == null && origin?.rawFragment == null &&
                        origin?.rawPath.isNullOrEmpty()
                ) { "Cross-origin requests are not allowed" }
            }
        }

        private fun validateBody(method: String, headers: Map<String, String>) {
            require(headers["transfer-encoding"] == null) { "Chunked request bodies are not supported" }
            val rawLength = headers["content-length"] ?: "0"
            val length = rawLength.toIntOrNull()
            require(rawLength.all { it in '0'..'9' } && length != null && length in 0..MaxHttpBodyBytes) {
                "Invalid or oversized Content-Length"
            }
            require(method in listOf("POST", "PUT") || length == 0) { "This method cannot have a body" }
            if (length > 0) {
                require(headers["content-type"]?.substringBefore(';')?.trim().equals("application/json", true)) {
                    "Request bodies must use application/json"
                }
            }
        }
    }
}

internal const val MaxNetworkRecordBytes = 16 * 1024 * 1024
private const val MaxHttpHeaderBytes = 16 * 1024
private const val MaxHttpBodyBytes = 2 * 1024 * 1024
private val HeaderName = Regex("[!#$%&'*+.^_`|~0-9a-z-]+")

private val BrowserHosts = setOf("localhost", "127.0.0.1", "[::1]")

private val InspectorOrigin = Regex("snapo-inspector://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

package com.openai.snapo.inspector

import java.io.OutputStream

data class InspectorHttpResponse(
    val statusCode: Int,
    val body: ByteArray,
    val allowedMethods: String? = null,
    val contentType: String = "application/json; charset=utf-8",
) {
    fun write(output: OutputStream, headers: Map<String, String> = emptyMap()) {
        writeHead(
            output,
            statusCode,
            headers + buildMap {
                put("Content-Type", contentType)
                put("Content-Length", body.size.toString())
                put("Connection", "close")
                allowedMethods?.let { put("Allow", it) }
            },
        )
        output.write(body)
        output.flush()
    }

    companion object {
        fun json(json: String, statusCode: Int = 200): InspectorHttpResponse =
            InspectorHttpResponse(statusCode, json.toByteArray(Charsets.UTF_8))

        fun text(text: String, statusCode: Int = 200): InspectorHttpResponse =
            InspectorHttpResponse(
                statusCode,
                text.toByteArray(Charsets.UTF_8),
                contentType = "text/plain; charset=utf-8"
            )

        fun error(statusCode: Int, message: String, allowedMethods: String? = null): InspectorHttpResponse =
            InspectorHttpResponse(
                statusCode,
                ("{\"error\":" + quoteJson(message) + "}").toByteArray(Charsets.UTF_8),
                allowedMethods
            )

        /** Writes headers for a streaming response. The caller owns its body and framing. */
        fun writeHead(output: OutputStream, statusCode: Int, headers: Map<String, String>) {
            val head = buildString {
                append("HTTP/1.1 $statusCode ${ReasonPhrases[statusCode] ?: "Error"}\r\n")
                headers.forEach { (name, value) ->
                    require(HeaderName.matches(name) && value.all { it.code in 32..126 }) { "Invalid response header" }
                    append("$name: $value\r\n")
                }
                append("\r\n")
            }
            output.write(head.toByteArray(Charsets.US_ASCII))
        }
    }
}

private val ReasonPhrases = mapOf(
    200 to "OK",
    201 to "Created",
    204 to "No Content",
    400 to "Bad Request",
    404 to "Not Found",
    405 to "Method Not Allowed",
    406 to "Not Acceptable",
    408 to "Request Timeout",
    409 to "Conflict",
    410 to "Gone",
    413 to "Payload Too Large",
    422 to "Unprocessable Entity",
    500 to "Internal Server Error",
    503 to "Service Unavailable",
    504 to "Gateway Timeout",
)

private val HeaderName = Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+")

private fun quoteJson(value: String): String = buildString {
    append('"')
    value.forEach { char ->
        when (char) {
            '"', '\\' -> {
                append('\\')
                append(char)
            }
            else -> if (char.code < 32) append("\\u%04x".format(char.code)) else append(char)
        }
    }
    append('"')
}

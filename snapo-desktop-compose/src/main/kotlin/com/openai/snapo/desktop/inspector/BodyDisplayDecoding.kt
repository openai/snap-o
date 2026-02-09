package com.openai.snapo.desktop.inspector

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64
import java.util.zip.GZIPInputStream

internal fun decodeBodyForDisplay(
    rawBody: String,
    rawEncoding: String?,
    contentEncodingHeader: String?,
): String {
    if (!rawEncoding.equals("base64", ignoreCase = true)) {
        return rawBody
    }
    if (!hasGzipContentEncoding(contentEncodingHeader)) {
        return rawBody
    }

    val decodedBytes = runCatching { Base64.getDecoder().decode(rawBody.trim()) }.getOrNull()
        ?: return rawBody
    val uncompressed = gunzipOrNull(decodedBytes) ?: return rawBody
    val decodedText = decodeUtf8StrictOrNull(uncompressed)
    if (decodedText != null) {
        return decodedText
    }

    return buildString {
        append("Binary payload after gzip decompression (")
        append(formatDisplayBytes(uncompressed.size.toLong()))
        append("). Raw payload is shown below as captured.")
        append("\n\n")
        append(rawBody)
    }
}

internal fun hasGzipContentEncoding(value: String?): Boolean {
    if (value.isNullOrBlank()) return false
    return value
        .split(',', '\n')
        .asSequence()
        .map { token -> token.substringBefore(';').trim().lowercase() }
        .filter { token -> token.isNotEmpty() }
        .any { token -> token == "gzip" || token == "x-gzip" }
}

private fun gunzipOrNull(bytes: ByteArray): ByteArray? {
    if (bytes.isEmpty()) return null
    return runCatching {
        GZIPInputStream(ByteArrayInputStream(bytes)).use { input ->
            val out = ByteArrayOutputStream(bytes.size.coerceAtLeast(256))
            val buffer = ByteArray(8192)
            while (true) {
                val read = input.read(buffer)
                if (read == -1) break
                out.write(buffer, 0, read)
            }
            out.toByteArray()
        }
    }.getOrNull()
}

private fun decodeUtf8StrictOrNull(bytes: ByteArray): String? {
    if (bytes.isEmpty()) return null
    return runCatching {
        val decoder = Charsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        decoder.decode(ByteBuffer.wrap(bytes)).toString()
    }.getOrNull()
}

private fun formatDisplayBytes(byteCount: Long): String {
    val kb = 1000.0
    val mb = kb * 1000.0
    val gb = mb * 1000.0
    val value = byteCount.toDouble()
    return when {
        value < kb -> "$byteCount B"
        value < mb -> "%.1f KB".format(value / kb)
        value < gb -> "%.1f MB".format(value / mb)
        else -> "%.1f GB".format(value / gb)
    }
}

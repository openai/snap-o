package com.openai.snapo.network.capture

import androidx.annotation.RestrictTo
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import kotlin.io.encoding.Base64

/**
 * Parsed content metadata shared by Snap-O's client-specific network integrations.
 *
 * This is library-group API. Applications should configure capture through their client integration.
 */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
data class BodyContentType(
    val type: String,
    val subtype: String,
    val charset: Charset? = null,
) {
    val isTextLike: Boolean
        get() {
            if (type.equals("text", ignoreCase = true)) return true
            val normalizedSubtype = subtype.lowercase()
            return TextLikeSubtypes.any(normalizedSubtype::contains)
        }

    val isEventStream: Boolean
        get() = type.equals("text", ignoreCase = true) &&
            subtype.equals("event-stream", ignoreCase = true)

    val isMultipartFormData: Boolean
        get() = type.equals("multipart", ignoreCase = true) &&
            subtype.equals("form-data", ignoreCase = true)

    fun charsetOrUtf8(): Charset = charset ?: Charsets.UTF_8

    companion object {
        @RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
        fun parse(value: String?): BodyContentType? {
            val parts = value?.split(';') ?: return null
            val typePieces = parts.firstOrNull()
                ?.trim()
                ?.split('/')
                .orEmpty()
            if (typePieces.size != 2) return null
            val type = typePieces[0].trim().lowercase()
            val subtype = typePieces[1].trim().lowercase()
            if (type.isEmpty() || subtype.isEmpty()) return null

            val charset = parts.asSequence()
                .drop(1)
                .mapNotNull(::extractCharset)
                .mapNotNull { rawCharset -> runCatching { Charset.forName(rawCharset) }.getOrNull() }
                .lastOrNull()
            return BodyContentType(type = type, subtype = subtype, charset = charset)
        }
    }
}

/** Raw response bytes captured by a client-specific stream wrapper. */
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
data class RawResponseBodyCapture(
    val bytes: ByteArray,
    val totalBytes: Long,
    val reachedEof: Boolean,
)

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
data class ResolvedRequestBody(
    val body: String?,
    val encoding: String?,
)

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
data class ResolvedResponseBody(
    val preview: String?,
    val body: String?,
    val encoding: String?,
    val truncatedBytes: Long?,
    val bodySize: Long,
)

@field:RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
const val DefaultBodyPreviewBytes: Int = 4096

@field:RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
const val DefaultTextBodyMaxBytes: Int = 5 * 1024 * 1024

@field:RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
const val DefaultBinaryBodyMaxBytes: Int = DefaultTextBodyMaxBytes

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun resolveEffectiveMaxBytes(maxBytes: Int, contentLength: Long?): Int {
    if (maxBytes <= 0) return 0
    val knownLength = contentLength?.takeIf { it >= 0L } ?: return maxBytes
    return if (knownLength < CompleteBodyCaptureThresholdBytes) {
        maxOf(maxBytes.toLong(), knownLength).toInt()
    } else {
        maxBytes
    }
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun resolveRequestCaptureLimit(
    contentType: BodyContentType?,
    contentEncoding: String?,
    textBodyMaxBytes: Int,
    binaryBodyMaxBytes: Int,
): Int = if (
    shouldEncodeBodyAsBase64(
        contentType = contentType,
        contentEncoding = contentEncoding,
    )
) {
    binaryBodyMaxBytes
} else {
    textBodyMaxBytes
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun resolveResponseCaptureLimit(
    contentType: BodyContentType?,
    contentLength: Long?,
    textBodyMaxBytes: Int,
    binaryBodyMaxBytes: Int,
    previewBytes: Int,
): Int {
    val bodyLimit = when {
        contentType == null -> maxOf(textBodyMaxBytes, binaryBodyMaxBytes)
        contentType.isTextLike -> textBodyMaxBytes
        else -> binaryBodyMaxBytes
    }
    return resolveEffectiveMaxBytes(
        maxBytes = maxOf(bodyLimit, previewBytes),
        contentLength = contentLength,
    )
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun shouldEncodeBodyAsBase64(
    contentType: BodyContentType?,
    contentEncoding: String?,
): Boolean {
    return hasNonIdentityContentEncoding(contentEncoding) || contentType?.isTextLike != true
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun resolveRequestBody(
    bytes: ByteArray?,
    contentType: BodyContentType?,
    contentEncoding: String?,
    hasBody: Boolean = true,
): ResolvedRequestBody {
    val usesBase64 = shouldEncodeBodyAsBase64(contentType, contentEncoding)
    if (bytes == null || bytes.isEmpty()) {
        return ResolvedRequestBody(
            body = null,
            encoding = "base64".takeIf { hasBody && usesBase64 },
        )
    }
    return if (usesBase64) {
        ResolvedRequestBody(body = Base64.encode(bytes), encoding = "base64")
    } else {
        ResolvedRequestBody(
            body = String(bytes, contentType?.charsetOrUtf8() ?: Charsets.UTF_8),
            encoding = null,
        )
    }
}

@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
fun resolveResponseBody(
    capture: RawResponseBodyCapture,
    contentType: BodyContentType?,
    textBodyMaxBytes: Int,
    binaryBodyMaxBytes: Int,
    previewBytes: Int,
    declaredBodySize: Long?,
): ResolvedResponseBody {
    val likelyText = capture.isLikelyText(contentType)
    val bodyLimit = resolveEffectiveMaxBytes(
        maxBytes = if (likelyText) textBodyMaxBytes else binaryBodyMaxBytes,
        contentLength = declaredBodySize,
    )
    val retainedBodyBytes = capture.bytes.prefix(bodyLimit)
    val previewSource = capture.bytes.prefix(previewBytes)
    val charset = contentType?.charsetOrUtf8() ?: Charsets.UTF_8
    val body = retainedBodyBytes.encodeForInspector(likelyText, charset)
    val preview = previewSource.encodeForInspector(likelyText, charset)
    val bodySize = capture.resolvedBodySize(declaredBodySize)
    val truncatedBytes = capture.resolvedTruncatedBytes(
        bodySize = bodySize,
        retainedBytes = retainedBodyBytes.size,
        hasDeclaredBodySize = declaredBodySize != null,
    )
    return ResolvedResponseBody(
        preview = preview,
        body = body,
        encoding = "base64".takeIf { body != null && !likelyText },
        truncatedBytes = truncatedBytes,
        bodySize = bodySize,
    )
}

private fun RawResponseBodyCapture.isLikelyText(contentType: BodyContentType?): Boolean = when {
    contentType?.isTextLike == true -> true
    contentType != null -> false
    else -> bytes.decodeUtf8TextIfLikely() != null
}

private fun ByteArray.encodeForInspector(likelyText: Boolean, charset: Charset): String? = when {
    isEmpty() -> null
    likelyText -> String(this, charset)
    else -> Base64.encode(this)
}

private fun RawResponseBodyCapture.resolvedBodySize(declaredBodySize: Long?): Long = when {
    reachedEof -> totalBytes
    declaredBodySize != null -> maxOf(declaredBodySize, totalBytes)
    else -> totalBytes
}

private fun RawResponseBodyCapture.resolvedTruncatedBytes(
    bodySize: Long,
    retainedBytes: Int,
    hasDeclaredBodySize: Boolean,
): Long? {
    val truncatedBytes = (bodySize - retainedBytes.toLong()).coerceAtLeast(0L)
    val truncationIsKnown = reachedEof || hasDeclaredBodySize || totalBytes > retainedBytes
    return truncatedBytes.takeIf { it > 0L && truncationIsKnown }
}

private fun ByteArray.prefix(maxBytes: Int): ByteArray {
    if (maxBytes <= 0 || isEmpty()) return ByteArray(0)
    return if (size <= maxBytes) this else copyOf(maxBytes)
}

private fun ByteArray.decodeUtf8TextIfLikely(): String? {
    if (isEmpty()) return ""
    val decoded = runCatching {
        Charsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(this))
            .toString()
    }.getOrNull() ?: return null
    if (decoded.isEmpty()) return decoded
    val printable = decoded.count { ch ->
        ch == '\n' || ch == '\r' || ch == '\t' || (ch >= ' ' && ch != '\u007f')
    }
    val printableRatio = printable.toDouble() / decoded.length.toDouble()
    return decoded.takeIf { printableRatio >= MinLikelyTextRatio }
}

private fun hasNonIdentityContentEncoding(contentEncoding: String?): Boolean {
    val encodings = contentEncoding
        ?.split(',')
        ?.map { token -> token.substringBefore(';').trim().lowercase() }
        ?.filter { token -> token.isNotEmpty() }
        .orEmpty()
    return encodings.any { token -> token != "identity" }
}

private fun extractCharset(parameter: String): String? {
    val trimmed = parameter.trim()
    if (!trimmed.startsWith("charset=", ignoreCase = true)) return null
    return trimmed.substringAfter('=').trim().trim('"').takeIf(String::isNotEmpty)
}

private val TextLikeSubtypes = listOf(
    "json",
    "xml",
    "html",
    "javascript",
    "form",
    "graphql",
    "plain",
    "csv",
    "yaml",
)

private const val MinLikelyTextRatio: Double = 0.85
private const val CompleteBodyCaptureThresholdBytes: Long = 8L * 1024L * 1024L

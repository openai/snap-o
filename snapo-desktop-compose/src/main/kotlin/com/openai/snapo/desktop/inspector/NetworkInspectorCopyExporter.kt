package com.openai.snapo.desktop.inspector

import java.awt.Toolkit
import java.awt.datatransfer.StringSelection
import java.util.Base64

object NetworkInspectorCopyExporter {
    fun copyUrl(url: String) = copyText(url)

    fun copyText(text: String) {
        val clipboard = Toolkit.getDefaultToolkit().systemClipboard
        clipboard.setContents(StringSelection(text), null)
    }

    fun copyCurl(request: NetworkInspectorRequestUiModel) {
        copyText(makeCurlCommand(request))
    }

    fun copyStreamEventsRaw(events: List<NetworkInspectorRequestUiModel.StreamEvent>) {
        val payload = events.joinToString(separator = "") { event ->
            val normalized = event.raw.replace(Regex("\\n+$"), "")
            normalized + "\n\n"
        }
        copyText(payload)
    }

    private fun makeCurlCommand(request: NetworkInspectorRequestUiModel): String {
        val warnings = mutableListOf<String>()
        val parts = mutableListOf<String>()

        parts += "--request ${singleQuoted(request.method)}"
        parts += "--url ${singleQuoted(request.url)}"

        for (header in request.requestHeaders) {
            parts += "--header ${singleQuoted("${header.name}: ${header.value}")}"
        }

        val bodyArg = makeBodyArgument(request, warnings)
        if (bodyArg != null) {
            parts += bodyArg
        }

        val command = joinCurlParts(parts)
        if (warnings.isEmpty()) return command

        val warningLines = warnings.map { "# $it" }
        return (warningLines + command).joinToString("\n")
    }

    private fun makeBodyArgument(
        request: NetworkInspectorRequestUiModel,
        warnings: MutableList<String>,
    ): String? {
        val body = request.requestBody ?: return null

        if (body.isPreview && body.truncatedBytes == null) {
            warnings += "Request body is a preview - copied data may be incomplete"
        }

        val truncated = body.truncatedBytes
        if (truncated != null && truncated > 0) {
            warnings += "Request body truncated by ${formatBytes(truncated)} - copied data may be incomplete"
        }

        val encoding = body.encoding?.lowercase()
        if (encoding == "base64") {
            val decoded = try {
                Base64.getDecoder().decode(body.rawText)
            } catch (_: Throwable) {
                null
            }

            return if (decoded != null) {
                "--data-binary ${makeBinaryLiteral(decoded)}"
            } else {
                warnings += "Unable to decode base64 body - copied data uses raw text"
                "--data-binary ${singleQuoted(body.rawText)}"
            }
        }

        return "--data-binary ${singleQuoted(body.rawText)}"
    }

    private fun joinCurlParts(parts: List<String>): String {
        if (parts.isEmpty()) return "curl"

        val remaining = parts.toMutableList()
        val first = remaining.removeFirst()
        var firstLine = "curl $first"

        if (remaining.isNotEmpty()) {
            val second = remaining.removeFirst()
            firstLine += " $second"
        }

        if (remaining.isEmpty()) return firstLine

        val lines = mutableListOf<String>()
        lines += "$firstLine \\"

        remaining.forEachIndexed { index, part ->
            val isLast = index == remaining.lastIndex
            lines += if (isLast) "  $part" else "  $part \\"
        }

        return lines.joinToString("\n")
    }

    private fun singleQuoted(value: String): String {
        if (value.isEmpty()) return "''"
        val escaped = value.replace("'", "'\"'\"'")
        return "'$escaped'"
    }

    private fun makeBinaryLiteral(data: ByteArray): String {
        val out = StringBuilder(data.size * 4)
        out.append("$'")

        for (b in data) {
            val byte = b.toInt() and 0xFF
            when (byte) {
                0x07 -> out.append("\\a")
                0x08 -> out.append("\\b")
                0x09 -> out.append("\\t")
                0x0A -> out.append("\\n")
                0x0B -> out.append("\\v")
                0x0C -> out.append("\\f")
                0x0D -> out.append("\\r")
                0x5C -> out.append("\\\\")
                0x27 -> out.append("\\'")
                in 0x20..0x7E -> out.append(byte.toChar())
                else -> out.append("\\x%02X".format(byte))
            }
        }

        out.append("'")
        return out.toString()
    }

    private fun formatBytes(byteCount: Long): String {
        // Keep it simple; ByteCountFormatter isn't available on the JVM stdlib.
        val kib = 1024.0
        val mib = kib * 1024.0
        val gib = mib * 1024.0

        val value = byteCount.toDouble()
        return when {
            value < kib -> "$byteCount B"
            value < mib -> "%.1f KiB".format(value / kib)
            value < gib -> "%.1f MiB".format(value / mib)
            else -> "%.1f GiB".format(value / gib)
        }
    }
}

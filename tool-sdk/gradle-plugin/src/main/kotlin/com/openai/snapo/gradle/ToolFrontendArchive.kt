package com.openai.snapo.gradle

import org.apache.commons.compress.archivers.zip.ZipFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.zip.CRC32

// Matches the macOS frontend bundle contract in contracts/tool-frontend/README.md.
internal fun validateToolFrontend(file: File) {
    require(file.length() <= MaxArchiveBytes) { "Tool frontend archive exceeds 16 MiB: $file" }
    ZipFile.builder().setFile(file).get().use { archive ->
        val seen = mutableSetOf<String>()
        var total = 0L
        var hasIndex = false
        for (entry in archive.entries) {
            val rawName = entry.rawName.toString(Charsets.UTF_8)
            val path = if (entry.isDirectory) rawName.removeSuffix("/") else rawName
            require(seen.size < 1024) { "Tool frontend contains more than 1024 entries: $file" }
            require(validFrontendPath(path) && seen.add(path)) { "Invalid or duplicate tool frontend path: ${entry.name}" }
            require(!entry.isUnixSymlink) { "Tool frontend cannot contain symbolic links: $path" }
            require(entry.size in 0..(MaxArchiveBytes - total)) { "Tool frontend exceeds 16 MiB expanded at: $path" }
            if (entry.isDirectory) continue
            require(entry.method in listOf(0, 8) && archive.canReadEntryData(entry)) {
                "Unsupported tool frontend ZIP entry: $path"
            }
            val html = if (path == "index.html") ByteArrayOutputStream() else null
            require(html == null || entry.size <= MaxHtmlBytes) { "Tool frontend index.html exceeds 4 MiB" }
            val checksum = CRC32()
            var size = 0L
            archive.getInputStream(entry).use { input ->
                val buffer = ByteArray(16384)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    size += count
                    require(size <= entry.size && total + size <= MaxArchiveBytes) {
                        "Tool frontend ZIP size mismatch at: $path"
                    }
                    checksum.update(buffer, 0, count)
                    html?.write(buffer, 0, count)
                }
            }
            require(size == entry.size && checksum.value == entry.crc) { "Tool frontend ZIP checksum or size mismatch: $path" }
            total += size
            if (html != null) {
                require(runCatching { Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(html.toByteArray())) }.isSuccess) {
                    "Tool frontend index.html must be UTF-8"
                }
                hasIndex = true
            }
        }
        require(hasIndex) { "Tool frontend must contain index.html at its root" }
    }
}

private fun validFrontendPath(path: String): Boolean =
    path.isNotEmpty() && path.length <= 1024 && '\\' !in path &&
        path.none { it.code < 32 || it.code == 127 } &&
        path.split('/').none { it.isEmpty() || it == "." || it == ".." }

private const val MaxArchiveBytes = 16 * 1024 * 1024L
private const val MaxHtmlBytes = 4 * 1024 * 1024L

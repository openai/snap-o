package com.openai.snapo.gradle

import org.apache.commons.compress.archivers.zip.ZipArchiveEntry
import org.apache.commons.compress.archivers.zip.ZipArchiveOutputStream
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ToolFrontendArchiveTest {
    @get:Rule val directory = TemporaryFolder()

    @Test fun `accepts a frontend with nested assets`() {
        validateToolFrontend(archive("index.html" to "<html>Example</html>".toByteArray(), "assets/app.js" to byteArrayOf(1)))
    }

    @Test fun `rejects missing invalid or oversized entry point`() {
        rejects(archive("app.js" to byteArrayOf()), "index.html")
        rejects(archive("index.html" to byteArrayOf(0xc3.toByte())), "UTF-8")
        rejects(archive("index.html" to ByteArray(4 * 1024 * 1024 + 1)), "4 MiB")
    }

    @Test fun `rejects unsafe and duplicate paths`() {
        for (name in listOf("../a", "/a", "a//b", "a/./b", "a\\b", "a\u0001", "a".repeat(1025))) {
            val file = directory.newFile()
            java.util.zip.ZipOutputStream(file.outputStream()).use { zip ->
                for (path in listOf("index.html", name)) {
                    zip.putNextEntry(java.util.zip.ZipEntry(path))
                    zip.closeEntry()
                }
            }
            rejects(file, "path")
        }
        rejects(archive("index.html" to byteArrayOf(), "index.html" to byteArrayOf()), "duplicate")
    }

    @Test fun `rejects symlinks`() {
        val file = directory.newFile()
        ZipArchiveOutputStream(file).use { zip ->
            val link = ZipArchiveEntry("index.html").apply { unixMode = 0xa1ff }
            zip.putArchiveEntry(link)
            zip.write("target.html".toByteArray())
            zip.closeArchiveEntry()
        }
        rejects(file, "symbolic links")
    }

    @Test fun `enforces compressed and expanded limits separately`() {
        val large = directory.newFile().apply { writeBytes(ByteArray(16 * 1024 * 1024 + 1)) }
        rejects(large, "archive exceeds")
        rejects(archive("index.html" to byteArrayOf(), "a" to ByteArray(8 * 1024 * 1024),
            "b" to ByteArray(8 * 1024 * 1024 + 1)), "expanded")
    }

    @Test fun `allows 1024 entries and rejects the next entry`() {
        val entries = (0 until 1023).map { "asset-$it" to byteArrayOf() }
        validateToolFrontend(archive("index.html" to byteArrayOf(), *entries.toTypedArray()))
        rejects(archive("index.html" to byteArrayOf(), *entries.toTypedArray(), "extra" to byteArrayOf()), "1024")
    }

    private fun rejects(file: File, message: String) {
        val failure = assertThrows(IllegalArgumentException::class.java) { validateToolFrontend(file) }
        assertTrue(failure.message, failure.message.orEmpty().contains(message))
    }

    private fun archive(vararg entries: Pair<String, ByteArray>): File = directory.newFile().also { file ->
        ZipArchiveOutputStream(file).use { zip ->
            for ((name, data) in entries) {
                zip.putArchiveEntry(ZipArchiveEntry(name))
                zip.write(data)
                zip.closeArchiveEntry()
            }
        }
    }
}

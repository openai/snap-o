package com.openai.snapo.gradle

import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault
import java.util.zip.ZipInputStream

@DisableCachingByDefault(because = "Restores a small resource from the plugin JAR")
abstract class ToolHostSdkTask : DefaultTask() {
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty

    @get:Input
    val bundledSdk: ByteArray
        get() = checkNotNull(javaClass.getResourceAsStream("/host-sdk/host-sdk.zip")) {
            "The Tool Packager plugin is missing its bundled host SDK."
        }.use { it.readBytes() }

    @TaskAction
    fun restore() {
        val directory = outputDirectory.get().asFile
        check(directory.deleteRecursively()) { "Cannot replace the generated host SDK: $directory" }
        directory.mkdirs()
        ZipInputStream(bundledSdk.inputStream()).use { archive ->
            var entry = archive.nextEntry
            while (entry != null) {
                val target = directory.resolve(entry.name).normalize()
                require(target.startsWith(directory)) { "Invalid bundled SDK path: ${entry.name}" }
                if (!entry.isDirectory) {
                    target.parentFile.mkdirs()
                    target.outputStream().use { archive.copyTo(it) }
                }
                entry = archive.nextEntry
            }
        }
    }
}

package com.openai.snapo.gradle

import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import javax.inject.Inject

@DisableCachingByDefault(because = "Checks managed Node installations for damage on every run")
abstract class PrepareNodeInstallationTask : DefaultTask() {
    @get:Inject abstract val fileSystem: FileSystemOperations
    @get:Input abstract val download: Property<Boolean>

    // Fingerprinting this directory can fail on the dangling links we need to remove.
    @get:Internal abstract val workDirectory: DirectoryProperty

    @TaskAction
    fun prepare() {
        if (!download.get()) return
        val directory = workDirectory.get().asFile.toPath()
        if (!Files.isDirectory(directory)) return
        Files.newDirectoryStream(directory, "node-v*").use { installations ->
            for (installation in installations) {
                if (!Files.isDirectory(installation, NOFOLLOW_LINKS)) continue
                val broken = Files.walk(installation).use { paths ->
                    paths.anyMatch { Files.isSymbolicLink(it) && !Files.exists(it) }
                }
                if (!broken) continue
                logger.lifecycle("Removing damaged Node installation: $installation")
                fileSystem.delete { delete(installation) }
            }
        }
    }
}

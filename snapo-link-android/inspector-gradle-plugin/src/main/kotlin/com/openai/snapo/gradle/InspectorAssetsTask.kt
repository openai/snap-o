package com.openai.snapo.gradle

import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import javax.inject.Inject
import java.util.zip.ZipFile

@CacheableTask
abstract class InspectorAssetsTask : DefaultTask() {
    @get:Input abstract val inspectorId: Property<String>
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val frontendArchive: RegularFileProperty
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    @get:Inject abstract val fileSystem: FileSystemOperations

    @TaskAction
    fun packageAssets() {
        val id = inspectorId.get()
        requireInspectorId(id)
        ZipFile(frontendArchive.get().asFile).use { archive ->
            require(archive.getEntry("index.html")?.isDirectory == false) {
                "Inspector frontend must contain index.html at its root"
            }
        }
        fileSystem.sync {
            from(frontendArchive)
            into(outputDirectory)
            eachFile { path = "snapo/inspectors/$id/$path" }
            includeEmptyDirs = false
        }
    }
}

internal fun requireInspectorId(id: String) {
    require(id.matches(Regex("[a-z][a-z0-9.-]{0,99}"))) { "Invalid inspector ID: $id" }
}

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

@CacheableTask
abstract class ToolAssetsTask : DefaultTask() {
    @get:Input abstract val toolId: Property<String>
    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val frontendArchive: RegularFileProperty
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    @get:Inject abstract val fileSystem: FileSystemOperations

    @TaskAction
    fun packageAssets() {
        val id = toolId.get()
        requireToolId(id)
        validateToolFrontend(frontendArchive.get().asFile)
        fileSystem.sync {
            from(frontendArchive)
            into(outputDirectory)
            eachFile { path = "snapo/inspectors/$id/$path" }
            includeEmptyDirs = false
        }
    }
}

internal fun requireToolId(id: String) {
    require(id.matches(Regex("[a-z][a-z0-9.-]{0,99}"))) { "Invalid tool ID: $id" }
}

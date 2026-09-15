package com.openai.snapo.gradle

import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.TaskAction
import org.gradle.work.DisableCachingByDefault

@DisableCachingByDefault(because = "Creates editable source files only when explicitly requested")
abstract class ToolFrontendInitTask : DefaultTask() {
    @get:Internal abstract val frontendDirectory: DirectoryProperty

    @TaskAction
    fun generate() {
        val directory = frontendDirectory.get().asFile
        require(!directory.exists() || directory.isDirectory && directory.listFiles()?.isEmpty() == true) {
            "Frontend directory is not empty: $directory. Choose an empty frontendDirectory."
        }
        val files = listOf(".gitignore", "index.html", "package.json", "tsconfig.json", "vite.config.ts", "src/main.tsx")
        val template = files.associateWith { name ->
            // Gradle excludes .gitignore from copied resources.
            val resource = if (name == ".gitignore") "gitignore" else name
            checkNotNull(javaClass.getResourceAsStream("/frontend-template/$resource")) {
                "Missing frontend template: $name"
            }.bufferedReader().use { it.readText() }
        }
        template.forEach { (name, content) ->
            val target = directory.resolve(name)
            target.parentFile.mkdirs()
            check(target.createNewFile()) { "Frontend file already exists: $target" }
            target.writeText(content)
        }
    }
}

package com.openai.snapo.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ToolFrontendInitTaskTest {
    @get:Rule val directory = TemporaryFolder()

    @Test
    fun `creates a starter in the configured directory and never overwrites it`() {
        val destination = directory.root.resolve("custom/ui")
        val task = initTask(destination)
        task.generate()

        assertTrue(destination.resolve("index.html").readText().contains("/src/main.tsx"))
        assertTrue(destination.resolve("package.json").readText().contains("@snap-o/tool-host"))
        assertTrue(destination.resolve("src/main.tsx").readText().contains("host.onError("))
        assertFalse(directory.root.resolve("frontend").exists())

        val source = destination.resolve("src/main.tsx")
        source.writeText("user edits")
        assertThrows(IllegalArgumentException::class.java) { task.generate() }
        assertEquals("user edits", source.readText())
    }

    @Test
    fun `rejects an occupied directory before writing any files`() {
        val destination = directory.newFolder("frontend")
        destination.resolve(".keep").writeText("existing")

        assertThrows(IllegalArgumentException::class.java) { initTask(destination).generate() }
        assertEquals(listOf(".keep"), destination.listFiles()!!.map { it.name })
    }

    @Test
    fun `accepts an empty directory but rejects a file as the destination`() {
        val destination = directory.newFolder("empty")
        initTask(destination).generate()
        assertTrue(destination.resolve("package.json").isFile)

        val file = directory.newFile("occupied")
        assertThrows(IllegalArgumentException::class.java) { initTask(file).generate() }
        assertTrue(file.isFile)
    }

    private fun initTask(destination: File): ToolFrontendInitTask {
        val project = ProjectBuilder.builder().withProjectDir(directory.newFolder()).build()
        return project.tasks.register("writeSnapoToolFrontend", ToolFrontendInitTask::class.java).get().apply {
            frontendDirectory.set(destination)
        }
    }
}

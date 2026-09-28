package com.openai.snapo.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Files
import java.nio.file.Path

class PrepareNodeInstallationTaskTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test
    fun `preserves healthy installations and unrelated directories`() {
        val task = task()
        val healthy = installation(task, "node-v22.0.0-linux-x64")
        Files.writeString(healthy.resolve("node"), "fixture")
        Files.createSymbolicLink(healthy.resolve("valid-link"), Path.of("node"))
        val unrelated = installation(task, "other")
        Files.createSymbolicLink(unrelated.resolve("dangling"), Path.of("missing"))
        task.prepare()
        assertTrue(Files.exists(healthy.resolve("valid-link")))
        assertTrue(Files.isSymbolicLink(unrelated.resolve("dangling")))
    }

    @Test
    fun `removes dangling links without deleting external targets`() {
        val task = task()
        val stale = installation(task, "node-v20.0.0-linux-x64")
        val external = temporary.newFolder("external").toPath()
        val marker = Files.writeString(external.resolve("keep"), "keep")
        Files.createSymbolicLink(stale.resolve("external"), external)
        Files.createSymbolicLink(stale.resolve("dangling"), Path.of("missing"))
        task.prepare()
        assertFalse(Files.exists(stale))
        assertTrue(Files.exists(marker))
    }

    @Test
    fun `skips recovery for installed Node`() {
        val task = task()
        val broken = installation(task, "node-v22.0.0-linux-x64")
        Files.createSymbolicLink(broken.resolve("dangling"), Path.of("missing"))
        task.download.set(false)
        task.prepare()
        assertTrue(Files.exists(broken))
    }

    private fun task(): PrepareNodeInstallationTask {
        val project = ProjectBuilder.builder().withProjectDir(temporary.newFolder()).build()
        return project.tasks.register("prepareNode", PrepareNodeInstallationTask::class.java).get().apply {
            download.set(true)
            workDirectory.set(temporary.newFolder())
        }
    }

    private fun installation(task: PrepareNodeInstallationTask, name: String): Path =
        Files.createDirectories(task.workDirectory.get().asFile.resolve(name).toPath())
}

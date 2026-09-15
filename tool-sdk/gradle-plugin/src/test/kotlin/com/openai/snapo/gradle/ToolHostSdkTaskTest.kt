package com.openai.snapo.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ToolHostSdkTaskTest {
    @get:Rule val directory = TemporaryFolder()

    @Test
    fun `restores the SDK after clean and removes stale generated files`() {
        val project = ProjectBuilder.builder().withProjectDir(directory.newFolder()).build()
        val task = project.tasks.register("prepareHost", ToolHostSdkTask::class.java).get()
        val frontend = directory.newFolder("frontend")
        val target = frontend.resolve(".gradle/tool-host")
        task.outputDirectory.set(target)
        frontend.resolve("main.ts").writeText("user source")
        task.restore()
        target.resolve("stale.js").writeText("old SDK file")
        task.restore()
        assertFalse(target.resolve("stale.js").exists())
        assertTrue(frontend.resolve("main.ts").readText() == "user source")
        target.deleteRecursively()
        task.restore()
        assertTrue(target.resolve("dist/index.js").isFile)
        assertTrue(target.resolve("dist/index.d.ts").isFile)
        assertTrue(target.resolve("package.json").readText().contains("@snap-o/tool-host"))
    }
}

package com.openai.snapo.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import javax.xml.parsers.DocumentBuilderFactory

class ToolMetadataTaskTest {
    @get:Rule val directory = TemporaryFolder()

    @Test
    fun `renaming a plugin updates its descriptor manifest and Android constants together`() {
        val task = metadataTask()
        task.generate()
        val initialResource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
        val initialDescriptor = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            .parse(initialResource).documentElement
        assertFalse(initialDescriptor.hasAttribute("protocolVersion"))
        assertEquals("@drawable/example_tool_icon", initialDescriptor.getAttribute("icon"))
        assertFalse(task.sourceDirectory.file("com/example/plugin/SnapOTool.java").get().asFile
            .readText().contains("PROTOCOL_VERSION"))
        val oldResource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
        task.toolId.set("renamed-plugin")
        task.generate()

        val resource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
        val descriptor = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(resource).documentElement
        assertFalse(oldResource.exists())
        assertEquals("renamed-plugin", descriptor.getAttribute("id"))
        assertTrue(task.manifestFile.get().asFile.readText().contains("snapo.inspector.renamed-plugin"))
        val source = task.sourceDirectory.file("com/example/plugin/SnapOTool.java").get().asFile.readText()
        assertTrue(source.contains("public static final String ID = \"renamed-plugin\";"))
        assertEquals("2", descriptor.getAttribute("hostApiVersion"))
    }

    @Test
    fun `icons must be drawable or mipmap references`() {
        val task = metadataTask()
        task.icon.unset()
        assertThrows(IllegalArgumentException::class.java) { task.generate() }
        for (invalid in listOf("", "tool_icon", "@string/name", "@drawable/", "@drawable/icon extra")) {
            task.icon.set(invalid)
            assertThrows(IllegalArgumentException::class.java) { task.generate() }
        }
        for (valid in listOf("@drawable/tool_icon", "@mipmap/tool_icon", "@android:drawable/ic_menu_info_details")) {
            task.icon.set(valid)
            task.generate()
            val resource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
            val descriptor = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(resource).documentElement
            assertEquals(valid, descriptor.getAttribute("icon"))
        }
    }

    private fun metadataTask(): ToolMetadataTask {
        val project = ProjectBuilder.builder().withProjectDir(directory.root).build()
        return project.tasks.create("metadata", ToolMetadataTask::class.java).apply {
            namespace.set("com.example.plugin")
            toolId.set("first")
            displayName.set("Example")
            icon.set("@drawable/example_tool_icon")
            resourceDirectory.set(directory.newFolder("resources"))
            sourceDirectory.set(directory.newFolder("sources"))
            manifestFile.set(directory.root.resolve("AndroidManifest.xml"))
        }
    }
}

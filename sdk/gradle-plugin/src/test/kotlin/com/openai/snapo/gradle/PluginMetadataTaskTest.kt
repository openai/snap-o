package com.openai.snapo.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import javax.xml.parsers.DocumentBuilderFactory

class PluginMetadataTaskTest {
    @get:Rule val directory = TemporaryFolder()

    @Test
    fun `renaming a plugin updates its descriptor manifest and Android constants together`() {
        val project = ProjectBuilder.builder().withProjectDir(directory.root).build()
        val task = project.tasks.create("metadata", PluginMetadataTask::class.java).apply {
            namespace.set("com.example.plugin")
            pluginId.set("first")
            displayName.set("Example")
            protocolVersion.set(1)
            hostApiVersion.set(1)
            resourceDirectory.set(directory.newFolder("resources"))
            sourceDirectory.set(directory.newFolder("sources"))
            manifestFile.set(directory.root.resolve("AndroidManifest.xml"))
        }
        task.generate()
        val oldResource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
        task.pluginId.set("renamed-plugin")
        task.protocolVersion.set(9)
        task.generate()

        val resource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
        val descriptor = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(resource).documentElement
        assertFalse(oldResource.exists())
        assertEquals("renamed-plugin", descriptor.getAttribute("id"))
        assertEquals("9", descriptor.getAttribute("protocolVersion"))
        assertTrue(task.manifestFile.get().asFile.readText().contains("snapo.inspector.renamed-plugin"))
        val source = task.sourceDirectory.file("com/example/plugin/SnapOPlugin.java").get().asFile.readText()
        assertTrue(source.contains("public static final String ID = \"renamed-plugin\";"))
        assertTrue(source.contains("public static final int PROTOCOL_VERSION = 9;"))
        assertTrue(source.contains("public static final int HOST_API_VERSION = 1;"))
    }
}

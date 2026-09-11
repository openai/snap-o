package com.openai.snapo.gradle

import org.gradle.testfixtures.ProjectBuilder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import javax.xml.parsers.DocumentBuilderFactory

class InspectorMetadataTaskTest {
    @get:Rule val directory = TemporaryFolder()

    @Test
    fun `renaming an inspector updates its descriptor manifest and Android constants together`() {
        val project = ProjectBuilder.builder().withProjectDir(directory.root).build()
        val task = project.tasks.create("metadata", InspectorMetadataTask::class.java).apply {
            namespace.set("com.example.tool")
            inspectorId.set("first")
            displayName.set("Example")
            protocolVersion.set(1)
            hostApiVersion.set(1)
            resourceDirectory.set(directory.newFolder("resources"))
            sourceDirectory.set(directory.newFolder("sources"))
            manifestFile.set(directory.root.resolve("AndroidManifest.xml"))
        }
        task.generate()
        val oldResource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
        task.inspectorId.set("renamed-tool")
        task.protocolVersion.set(9)
        task.generate()

        val resource = task.resourceDirectory.get().asFile.resolve("xml").listFiles()!!.single()
        val descriptor = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(resource).documentElement
        assertFalse(oldResource.exists())
        assertEquals("renamed-tool", descriptor.getAttribute("id"))
        assertEquals("9", descriptor.getAttribute("protocolVersion"))
        assertTrue(task.manifestFile.get().asFile.readText().contains("snapo.inspector.renamed-tool"))
        val source = task.sourceDirectory.file("com/example/tool/SnapOInspector.java").get().asFile.readText()
        assertTrue(source.contains("public static final String ID = \"renamed-tool\";"))
        assertTrue(source.contains("public static final int PROTOCOL_VERSION = 9;"))
        assertTrue(source.contains("public static final int HOST_API_VERSION = 1;"))
    }
}

package com.openai.snapo.gradle

import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.TaskAction

@CacheableTask
abstract class InspectorMetadataTask : DefaultTask() {
    @get:Input abstract val namespace: Property<String>
    @get:Input abstract val inspectorId: Property<String>
    @get:Input abstract val displayName: Property<String>
    @get:Input abstract val protocolVersion: Property<Int>
    @get:Input @get:Optional abstract val icon: Property<String>
    @get:Input abstract val hostApiVersion: Property<Int>
    @get:OutputDirectory abstract val resourceDirectory: DirectoryProperty
    @get:OutputDirectory abstract val sourceDirectory: DirectoryProperty
    @get:OutputFile abstract val manifestFile: RegularFileProperty

    @TaskAction
    fun generate() {
        val id = inspectorId.get()
        requireInspectorId(id)
        require(displayName.get().isNotBlank() && displayName.get().length <= 200) {
            "Inspector display name must contain between 1 and 200 characters"
        }
        require(protocolVersion.get() > 0) { "Inspector protocol version must be positive" }
        require(hostApiVersion.get() > 0) { "Inspector host API version must be positive" }
        val source = sourceDirectory.file("${namespace.get().replace('.', '/')}/SnapOInspector.java").get().asFile
        sourceDirectory.get().asFile.deleteRecursively()
        source.parentFile.mkdirs()
        source.writeText("""
            package ${namespace.get()};

            /** Generated from snapoInspector. */
            public final class SnapOInspector {
                public static final String ID = "$id";
                public static final int PROTOCOL_VERSION = ${protocolVersion.get()};
                public static final int HOST_API_VERSION = ${hostApiVersion.get()};

                private SnapOInspector() {}
            }
        """.trimIndent() + "\n")
        // Hex preserves unique IDs when punctuation is not valid in resource names.
        val resourceName = "snapo_inspector_" + id.toByteArray().joinToString("") { "%02x".format(it) }
        val resource = resourceDirectory.file("xml/$resourceName.xml").get().asFile
        resourceDirectory.get().asFile.deleteRecursively()
        resource.parentFile.mkdirs()
        val iconAttribute = icon.orNull?.let { " icon=\"${xml(it)}\"" } ?: ""
        resource.writeText("""
            <?xml version="1.0" encoding="utf-8"?>
            <inspector version="1" id="$id" name="${xml(displayName.get())}"
                protocolVersion="${protocolVersion.get()}"$iconAttribute
                frontendAssets="snapo/inspectors/$id/frontend.zip"
                hostApiVersion="${hostApiVersion.get()}" />
        """.trimIndent() + "\n")
        val manifest = manifestFile.get().asFile
        manifest.parentFile.mkdirs()
        manifest.writeText("""
            <?xml version="1.0" encoding="utf-8"?>
            <manifest xmlns:android="http://schemas.android.com/apk/res/android">
                <application>
                    <meta-data android:name="snapo.inspector.$id" android:resource="@xml/$resourceName" />
                </application>
            </manifest>
        """.trimIndent() + "\n")
    }

    private fun xml(value: String): String = value.replace("&", "&amp;")
        .replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;")
}

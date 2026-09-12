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
abstract class ToolMetadataTask : DefaultTask() {
    @get:Input abstract val namespace: Property<String>
    @get:Input abstract val toolId: Property<String>
    @get:Input abstract val displayName: Property<String>
    @get:Input @get:Optional abstract val protocolVersion: Property<Int>
    @get:Input abstract val icon: Property<String>
    @get:OutputDirectory abstract val resourceDirectory: DirectoryProperty
    @get:OutputDirectory abstract val sourceDirectory: DirectoryProperty
    @get:OutputFile abstract val manifestFile: RegularFileProperty

    @TaskAction
    fun generate() {
        val id = toolId.get()
        requireToolId(id)
        require(displayName.get().isNotBlank() && displayName.get().length <= 200) {
            "Tool display name must contain between 1 and 200 characters"
        }
        val protocol = protocolVersion.orNull
        require(protocol == null || protocol > 0) { "Tool protocol version must be positive" }
        val protocolConstant = protocol?.let { "public static final int PROTOCOL_VERSION = $it;" } ?: ""
        val protocolAttribute = protocol?.let { " protocolVersion=\"$it\"" } ?: ""
        val iconReference = icon.orNull
        require(iconReference != null && ICON_REFERENCE.matches(iconReference)) {
            "Tool icon must reference a drawable or mipmap resource, such as @drawable/tool_icon"
        }
        val source = sourceDirectory.file("${namespace.get().replace('.', '/')}/SnapOTool.java").get().asFile
        sourceDirectory.get().asFile.deleteRecursively()
        source.parentFile.mkdirs()
        source.writeText("""
            package ${namespace.get()};

            /** Generated from snapoTool. */
            public final class SnapOTool {
                public static final String ID = "$id";
                $protocolConstant

                private SnapOTool() {}
            }
        """.trimIndent() + "\n")
        // Hex preserves unique IDs when punctuation is not valid in resource names.
        val resourceName = "snapo_inspector_" + id.toByteArray().joinToString("") { "%02x".format(it) }
        val resource = resourceDirectory.file("xml/$resourceName.xml").get().asFile
        resourceDirectory.get().asFile.deleteRecursively()
        resource.parentFile.mkdirs()
        resource.writeText("""
            <?xml version="1.0" encoding="utf-8"?>
            <inspector version="1" id="$id" name="${xml(displayName.get())}"
                icon="${xml(iconReference)}"$protocolAttribute
                frontendAssets="snapo/inspectors/$id/frontend.zip"
                hostApiVersion="$HOST_API_VERSION" />
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

    private companion object {
        const val HOST_API_VERSION = 1
        val ICON_REFERENCE = Regex("@(?:[a-zA-Z_][a-zA-Z0-9_.]*:)?(?:drawable|mipmap)/[a-z_][a-z0-9_]*")
    }
}

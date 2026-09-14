package com.openai.snapo.gradle

import com.android.build.api.variant.AndroidComponentsExtension
import com.github.gradle.node.NodeExtension
import com.github.gradle.node.NodePlugin
import com.github.gradle.node.npm.task.NpmInstallTask
import com.github.gradle.node.npm.task.NpmTask
import org.gradle.api.Action
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.bundling.Zip
import org.gradle.kotlin.dsl.create
import org.gradle.kotlin.dsl.getByType
import org.gradle.kotlin.dsl.named
import org.gradle.kotlin.dsl.register
import org.gradle.kotlin.dsl.withType
import org.gradle.process.ExecSpec

abstract class ToolBuildTask : NpmTask() {
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
}

class ToolPackagerPlugin : Plugin<Project> {
    override fun apply(project: Project) = with(project) {
        val tool = extensions.create<ToolExtension>("snapoTool")
        tool.frontendDirectory.convention(layout.projectDirectory.dir("frontend"))

        pluginManager.apply(NodePlugin::class.java)
        extensions.getByType<NodeExtension>().apply {
            version.set("22.23.2")
            download.set(true)
            nodeProjectDir.set(tool.frontendDirectory)
            npmInstallCommand.set("ci")
            enableTaskRules.set(false)
        }
        val downloadNode = extensions.getByType<NodeExtension>().download
        val installedPath = providers.environmentVariable("Path").orElse(providers.environmentVariable("PATH"))
        tasks.withType<NpmTask>().configureEach {
            // node-gradle 7.1.0 prepends its cached runtime even when download is false.
            execOverrides.convention(downloadNode.zip(installedPath) { download, path ->
                Action<ExecSpec> {
                    if (!download) {
                        val key = if (environment.containsKey("Path")) "Path" else "PATH"
                        environment(key, path)
                    }
                }
            })
        }
        val install = tasks.named<NpmInstallTask>(NpmInstallTask.NAME)
        val build = tasks.register<ToolBuildTask>("toolBuild") {
            group = "snapo"
            description = "Builds the tool frontend."
            inputs.files(install).withPropertyName("frontendDependencies").withPathSensitivity(PathSensitivity.RELATIVE)
            npmCommand.set(listOf("run", "build"))
            inputs.files(tool.frontendDirectory.map {
                it.asFileTree.matching { exclude("node_modules/**", "dist/**", ".gradle/**") }
            }).withPropertyName("frontendSources").withPathSensitivity(PathSensitivity.RELATIVE)
            outputDirectory.convention(tool.frontendDirectory.dir("dist"))
        }
        tool.frontendAssets.convention(build.flatMap { it.outputDirectory })
        val archive = tasks.register<Zip>("toolZip") {
            group = "snapo"
            description = "Packages the tool frontend."
            from(tool.frontendAssets)
            archiveFileName.set("frontend.zip")
            destinationDirectory.set(layout.buildDirectory.dir("intermediates/snapo/frontend"))
            isPreserveFileTimestamps = false
            isReproducibleFileOrder = true
        }
        tasks.register<NpmTask>("toolDev") {
            group = "snapo"
            description = "Runs the tool development server until stopped."
            dependsOn(install)
            npmCommand.set(listOf("run", "dev"))
        }

        listOf("com.android.application", "com.android.library").forEach { androidPlugin ->
            pluginManager.withPlugin(androidPlugin) {
                extensions.getByType(AndroidComponentsExtension::class.java).onVariants { variant ->
                    val suffix = variant.name.replaceFirstChar { it.uppercaseChar() }
                    val assets = tasks.register<ToolAssetsTask>("package${suffix}ToolAssets") {
                        toolId.set(tool.id)
                        frontendArchive.set(archive.flatMap { it.archiveFile })
                    }
                    val metadata = tasks.register<ToolMetadataTask>("generate${suffix}ToolMetadata") {
                        namespace.set(variant.namespace)
                        toolId.set(tool.id)
                        displayName.set(tool.displayName)
                        icon.set(tool.icon)
                    }
                    variant.sources.assets?.addGeneratedSourceDirectory(assets, ToolAssetsTask::outputDirectory)
                    variant.sources.res?.addGeneratedSourceDirectory(metadata, ToolMetadataTask::resourceDirectory)
                    variant.sources.java?.addGeneratedSourceDirectory(metadata, ToolMetadataTask::sourceDirectory)
                    variant.sources.manifests.addGeneratedManifestFile(metadata, ToolMetadataTask::manifestFile)
                }
            }
        }
    }
}

package com.openai.snapo.gradle

import com.android.build.api.variant.AndroidComponentsExtension
import com.github.gradle.node.NodeExtension
import com.github.gradle.node.NodePlugin
import com.github.gradle.node.npm.task.NpmInstallTask
import com.github.gradle.node.npm.task.NpmTask
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

abstract class PluginBuildTask : NpmTask() {
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
}

class PluginPackagingPlugin : Plugin<Project> {
    override fun apply(project: Project) = with(project) {
        val plugin = extensions.create<PluginExtension>("snapoPlugin")
        plugin.frontendDirectory.convention(layout.projectDirectory.dir("frontend"))
        plugin.hostApiVersion.convention(1)
        plugin.downloadNode.convention(true)
        plugin.nodeVersion.convention("22.23.2")

        pluginManager.apply(NodePlugin::class.java)
        extensions.getByType<NodeExtension>().apply {
            download.set(plugin.downloadNode)
            version.set(plugin.nodeVersion)
            // The settings plugin declares the repository, including in builds that forbid project repositories.
            distBaseUrl.set(null as String?)
            nodeProjectDir.set(plugin.frontendDirectory)
            npmInstallCommand.set("ci")
            enableTaskRules.set(false)
        }
        val install = tasks.named<NpmInstallTask>(NpmInstallTask.NAME)
        val build = tasks.register<PluginBuildTask>("pluginBuild") {
            group = "snapo"
            description = "Builds the plugin frontend."
            inputs.files(install).withPropertyName("frontendDependencies").withPathSensitivity(PathSensitivity.RELATIVE)
            npmCommand.set(listOf("run", "build"))
            inputs.files(plugin.frontendDirectory.map {
                it.asFileTree.matching { exclude("node_modules/**", "dist/**", ".gradle/**") }
            }).withPropertyName("frontendSources").withPathSensitivity(PathSensitivity.RELATIVE)
            outputDirectory.convention(plugin.frontendDirectory.dir("dist"))
        }
        plugin.frontendAssets.convention(build.flatMap { it.outputDirectory })
        val archive = tasks.register<Zip>("toolZip") {
            group = "snapo"
            description = "Packages the plugin frontend."
            from(plugin.frontendAssets)
            archiveFileName.set("frontend.zip")
            destinationDirectory.set(layout.buildDirectory.dir("intermediates/snapo/frontend"))
            isPreserveFileTimestamps = false
            isReproducibleFileOrder = true
        }
        tasks.register<NpmTask>("pluginDev") {
            group = "snapo"
            description = "Runs the plugin development server until stopped."
            dependsOn(install)
            npmCommand.set(listOf("run", "dev"))
        }

        listOf("com.android.application", "com.android.library").forEach { androidPlugin ->
            pluginManager.withPlugin(androidPlugin) {
                extensions.getByType(AndroidComponentsExtension::class.java).onVariants { variant ->
                    val suffix = variant.name.replaceFirstChar { it.uppercaseChar() }
                    val assets = tasks.register<PluginAssetsTask>("package${suffix}PluginAssets") {
                        pluginId.set(plugin.id)
                        frontendArchive.set(archive.flatMap { it.archiveFile })
                    }
                    val metadata = tasks.register<PluginMetadataTask>("generate${suffix}PluginMetadata") {
                        namespace.set(variant.namespace)
                        pluginId.set(plugin.id)
                        displayName.set(plugin.displayName)
                        protocolVersion.set(plugin.protocolVersion)
                        icon.set(plugin.icon)
                        hostApiVersion.set(plugin.hostApiVersion)
                    }
                    variant.sources.assets?.addGeneratedSourceDirectory(assets, PluginAssetsTask::outputDirectory)
                    variant.sources.res?.addGeneratedSourceDirectory(metadata, PluginMetadataTask::resourceDirectory)
                    variant.sources.java?.addGeneratedSourceDirectory(metadata, PluginMetadataTask::sourceDirectory)
                    variant.sources.manifests.addGeneratedManifestFile(metadata, PluginMetadataTask::manifestFile)
                }
            }
        }
    }
}

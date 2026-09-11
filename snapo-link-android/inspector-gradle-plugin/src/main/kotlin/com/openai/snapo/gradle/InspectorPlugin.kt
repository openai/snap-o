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

abstract class InspectorBuildTask : NpmTask() {
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
}

class InspectorPlugin : Plugin<Project> {
    override fun apply(project: Project) = with(project) {
        val inspector = extensions.create<InspectorExtension>("snapoInspector")
        inspector.frontendDirectory.convention(layout.projectDirectory.dir("frontend"))
        inspector.hostApiVersion.convention(1)
        inspector.downloadNode.convention(true)
        inspector.nodeVersion.convention("22.23.2")

        pluginManager.apply(NodePlugin::class.java)
        extensions.getByType<NodeExtension>().apply {
            download.set(inspector.downloadNode)
            version.set(inspector.nodeVersion)
            // The settings plugin declares the repository, including in builds that forbid project repositories.
            distBaseUrl.set(null as String?)
            nodeProjectDir.set(inspector.frontendDirectory)
            npmInstallCommand.set("ci")
            enableTaskRules.set(false)
        }
        val install = tasks.named<NpmInstallTask>(NpmInstallTask.NAME)
        val build = tasks.register<InspectorBuildTask>("inspectorBuild") {
            group = "snapo"
            description = "Builds the inspector frontend."
            inputs.files(install).withPropertyName("frontendDependencies").withPathSensitivity(PathSensitivity.RELATIVE)
            npmCommand.set(listOf("run", "build"))
            inputs.files(inspector.frontendDirectory.map {
                it.asFileTree.matching { exclude("node_modules/**", "dist/**", ".gradle/**") }
            }).withPropertyName("frontendSources").withPathSensitivity(PathSensitivity.RELATIVE)
            outputDirectory.convention(inspector.frontendDirectory.dir("dist"))
        }
        inspector.frontendAssets.convention(build.flatMap { it.outputDirectory })
        val archive = tasks.register<Zip>("inspectorZip") {
            group = "snapo"
            description = "Packages the inspector frontend."
            from(inspector.frontendAssets)
            archiveFileName.set("frontend.zip")
            destinationDirectory.set(layout.buildDirectory.dir("intermediates/snapo/frontend"))
            isPreserveFileTimestamps = false
            isReproducibleFileOrder = true
        }
        tasks.register<NpmTask>("inspectorDev") {
            group = "snapo"
            description = "Runs the inspector development server until stopped."
            dependsOn(install)
            npmCommand.set(listOf("run", "dev"))
        }

        listOf("com.android.application", "com.android.library").forEach { androidPlugin ->
            pluginManager.withPlugin(androidPlugin) {
                extensions.getByType(AndroidComponentsExtension::class.java).onVariants { variant ->
                    val suffix = variant.name.replaceFirstChar { it.uppercaseChar() }
                    val assets = tasks.register<InspectorAssetsTask>("package${suffix}InspectorAssets") {
                        inspectorId.set(inspector.id)
                        frontendArchive.set(archive.flatMap { it.archiveFile })
                    }
                    val metadata = tasks.register<InspectorMetadataTask>("generate${suffix}InspectorMetadata") {
                        namespace.set(variant.namespace)
                        inspectorId.set(inspector.id)
                        displayName.set(inspector.displayName)
                        protocolVersion.set(inspector.protocolVersion)
                        icon.set(inspector.icon)
                        hostApiVersion.set(inspector.hostApiVersion)
                    }
                    variant.sources.assets?.addGeneratedSourceDirectory(assets, InspectorAssetsTask::outputDirectory)
                    variant.sources.res?.addGeneratedSourceDirectory(metadata, InspectorMetadataTask::resourceDirectory)
                    variant.sources.java?.addGeneratedSourceDirectory(metadata, InspectorMetadataTask::sourceDirectory)
                    variant.sources.manifests.addGeneratedManifestFile(metadata, InspectorMetadataTask::manifestFile)
                }
            }
        }
    }
}

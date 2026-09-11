package com.openai.snapo.buildlogic.publishing

import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ListProperty
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.TaskAction
import org.gradle.language.base.plugins.LifecycleBasePlugin
import org.gradle.kotlin.dsl.register

private const val SAMPLE_PROJECT_PREFIX = ":samples:"
private const val PUBLICATION_ASSEMBLY_TASK = "assembleMavenCentralPublication"

class MavenCentralReleaseValidationPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        if (target != target.rootProject) {
            throw GradleException("snapo.maven.release-validation must be applied to the root project")
        }

        val validation = target.tasks.register<ValidateMavenCentralReleaseTask>(
            "validateMavenCentralRelease",
        ) {
            group = LifecycleBasePlugin.VERIFICATION_GROUP
            description = "Builds Maven Central release artifacts and debug sample applications."
            publicationManifest.set(
                target.layout.buildDirectory.file("reports/maven-central/publications.tsv"),
            )
        }

        target.subprojects.forEach { project ->
            project.pluginManager.withPlugin("snapo.maven.publish") {
                if (project.path.startsWith(SAMPLE_PROJECT_PREFIX)) {
                    throw GradleException("Sample project ${project.path} must not publish to Maven Central")
                }

                validation.configure {
                    dependsOn("${project.path}:$PUBLICATION_ASSEMBLY_TASK")
                    publications.add(
                        project.provider {
                            "${project.path}\t${project.group}:${project.name}:${project.version}"
                        },
                    )
                }
            }

            listOf("com.android.application", "com.android.library").forEach { pluginId ->
                project.pluginManager.withPlugin(pluginId) {
                    if (project.path.startsWith(SAMPLE_PROJECT_PREFIX)) {
                        validation.configure {
                            dependsOn("${project.path}:assembleDebug")
                        }
                    }
                }
            }
        }
    }
}

@CacheableTask
abstract class ValidateMavenCentralReleaseTask : DefaultTask() {
    @get:Input
    abstract val publications: ListProperty<String>

    @get:OutputFile
    abstract val publicationManifest: RegularFileProperty

    @TaskAction
    fun writePublicationManifest() {
        val entries = publications.get().distinct().sorted()
        if (entries.isEmpty()) {
            throw GradleException("No Maven Central publications were discovered")
        }

        val manifest = publicationManifest.get().asFile
        manifest.parentFile.mkdirs()
        manifest.writeText(entries.joinToString(separator = "\n", postfix = "\n"))
        logger.lifecycle("Validated ${entries.size} Maven Central publications; manifest: $manifest")
    }
}

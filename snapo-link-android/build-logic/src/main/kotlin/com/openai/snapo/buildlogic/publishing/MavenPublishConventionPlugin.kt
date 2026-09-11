package com.openai.snapo.buildlogic.publishing

import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import com.vanniktech.maven.publish.SourcesJar
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.publish.PublishingExtension
import org.gradle.plugins.signing.Sign
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.register

class MavenPublishConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        target.pluginManager.withPlugin("com.android.library") {
            target.pluginManager.apply("com.vanniktech.maven.publish")

            target.extensions.configure<MavenPublishBaseExtension> {
                configure(
                    AndroidSingleVariantLibrary(
                        javadocJar = JavadocJar.Empty(),
                        sourcesJar = SourcesJar.Sources(),
                        variant = "release",
                    ),
                )
                coordinates(
                    groupId = target.group.toString(),
                    artifactId = target.name,
                    version = target.version.toString(),
                )
                publishToMavenCentral()
                signAllPublications()

                pom {
                    name.set("Snap-O ${target.name}")
                    description.set(target.provider { target.description })
                    inceptionYear.set("2025")
                    url.set("https://github.com/openai/snap-o")

                    licenses {
                        license {
                            name.set("The Apache License, Version 2.0")
                            url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                            distribution.set("repo")
                        }
                    }
                    developers {
                        developer {
                            id.set("openai")
                            name.set("OpenAI")
                            url.set("https://openai.com")
                        }
                    }
                    scm {
                        url.set("https://github.com/openai/snap-o")
                        connection.set("scm:git:https://github.com/openai/snap-o.git")
                        developerConnection.set("scm:git:ssh://git@github.com/openai/snap-o.git")
                    }
                }
            }

            target.extensions.configure<PublishingExtension> {
                repositories.maven {
                    name = "Authoring"
                    url = target.uri(target.providers.gradleProperty("snapo.authoringRepository").getOrElse(
                        target.layout.buildDirectory.dir("authoring-repository").get().asFile.absolutePath,
                    ))
                    require(url.scheme == "file") { "Authoring publications require a local directory" }
                }
            }
            target.tasks.withType(Sign::class.java).configureEach {
                onlyIf {
                    !target.providers.gradleProperty("snapo.localAuthoring").map(String::toBoolean).getOrElse(false)
                }
            }

            target.tasks.register("assembleMavenCentralPublication") {
                group = "publishing"
                description = "Assembles the release artifacts and metadata published to Maven Central."
                dependsOn(
                    "bundleReleaseAar",
                    "emptyJavadocJar",
                    "sourceReleaseJar",
                    "generateMetadataFileForMavenPublication",
                    "generatePomFileForMavenPublication",
                )
            }
        }
    }
}

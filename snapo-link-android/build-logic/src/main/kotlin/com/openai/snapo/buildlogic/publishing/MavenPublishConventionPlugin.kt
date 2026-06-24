package com.openai.snapo.buildlogic.publishing

import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.JavadocJar
import com.vanniktech.maven.publish.MavenPublishBaseExtension
import com.vanniktech.maven.publish.SourcesJar
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure

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
        }
    }
}

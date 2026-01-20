package com.openai.snapo.buildlogic.android

import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.publish.PublishingExtension
import org.gradle.api.publish.maven.MavenPublication
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.create
import org.gradle.kotlin.dsl.getByType

class AndroidLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        target.pluginManager.apply("com.android.library")
        target.pluginManager.apply("maven-publish")

        val extension = target.extensions.getByType<LibraryExtension>()
        extension.apply {
            compileSdk = 36

            defaultConfig {
                minSdk = 24
            }

            buildTypes {
                maybeCreate("release").apply {
                    isMinifyEnabled = false
                }
            }

            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_11
                targetCompatibility = JavaVersion.VERSION_11
            }

            publishing {
                singleVariant("release") {
                    withSourcesJar()
                }
            }
        }

        target.afterEvaluate {
            val releaseComponent = components.findByName("release") ?: return@afterEvaluate

            extensions.configure<PublishingExtension> {
                publications {
                    if (findByName("release") == null) {
                        create<MavenPublication>("release") {
                            from(releaseComponent)
                            groupId = this@afterEvaluate.group.toString()
                            artifactId = this@afterEvaluate.name
                            version = this@afterEvaluate.version.toString()
                        }
                    }
                }
            }
        }
    }
}

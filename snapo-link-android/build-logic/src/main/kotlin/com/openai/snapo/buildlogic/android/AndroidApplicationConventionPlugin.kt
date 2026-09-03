package com.openai.snapo.buildlogic.android

import com.android.build.api.dsl.ApplicationExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.getByType

class AndroidApplicationConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        target.pluginManager.apply("com.android.application")

        val extension = target.extensions.getByType<ApplicationExtension>()
        extension.apply {
            compileSdk = 36

            defaultConfig {
                minSdk = 24
                targetSdk = 36
            }

            buildTypes {
                maybeCreate("release").apply {
                    isMinifyEnabled = target.providers.gradleProperty("snapo.samples.minifyRelease")
                        .map(String::toBooleanStrict)
                        .getOrElse(true)
                    isShrinkResources = false
                    proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
                }
            }

            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_11
                targetCompatibility = JavaVersion.VERSION_11
            }
        }

    }
}

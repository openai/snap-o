package com.openai.snapo.buildlogic.android

import com.android.build.api.dsl.ApplicationExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.getByType
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

class AndroidApplicationConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        target.pluginManager.apply("com.android.application")
        target.pluginManager.apply("org.jetbrains.kotlin.android")

        val extension = target.extensions.getByType<ApplicationExtension>()
        extension.apply {
            compileSdk = 36

            defaultConfig {
                minSdk = 24
                targetSdk = 36
            }

            buildTypes {
                maybeCreate("release").apply {
                    // Keep release builds lightweight for samples without extra optimization steps.
                    isMinifyEnabled = false
                    isShrinkResources = false
                }
            }

            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_11
                targetCompatibility = JavaVersion.VERSION_11
            }
        }

        target.extensions.configure<KotlinAndroidProjectExtension> {
            compilerOptions.jvmTarget.set(JvmTarget.JVM_11)
        }
    }
}

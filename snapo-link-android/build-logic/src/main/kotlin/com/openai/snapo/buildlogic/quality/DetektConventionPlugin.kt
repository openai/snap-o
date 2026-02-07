package com.openai.snapo.buildlogic.quality

import io.gitlab.arturbosch.detekt.Detekt
import io.gitlab.arturbosch.detekt.extensions.DetektExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.getByType
import org.gradle.kotlin.dsl.withType
import kotlin.jvm.optionals.getOrElse

class DetektConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        target.pluginManager.apply("io.gitlab.arturbosch.detekt")

        val libraries = target.rootProject.extensions
            .getByType<VersionCatalogsExtension>()
            .named("libs")
        val detektVersion = libraries.findVersion("detekt")
            .getOrElse { throw IllegalStateException("detekt version not found in version catalog") }
            .requiredVersion

        target.dependencies {
            add(
                "detektPlugins",
                "io.gitlab.arturbosch.detekt:detekt-formatting:$detektVersion"
            )
        }

        target.extensions.configure<DetektExtension> {
            toolVersion = detektVersion
            buildUponDefaultConfig = true
            autoCorrect = true
            config.setFrom(target.rootProject.file("config/detekt/detekt.yml"))
            ignoreFailures = false
        }

        target.tasks.withType<Detekt>().configureEach {
            jvmTarget = "11"
            reports.apply {
                sarif.required.set(false)
                txt.required.set(false)
                xml.required.set(false)
                md.required.set(false)
                html.required.set(true)
            }
        }
    }
}

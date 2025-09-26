package com.openai.snapo.buildlogic.quality

import io.gitlab.arturbosch.detekt.Detekt
import io.gitlab.arturbosch.detekt.extensions.DetektExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.withType

class DetektConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) {
        target.pluginManager.apply("io.gitlab.arturbosch.detekt")

        target.extensions.configure<DetektExtension> {
            toolVersion = "1.23.6"
            buildUponDefaultConfig = true
            autoCorrect = false
            config.setFrom(target.rootProject.file("config/detekt/detekt.yml"))
            ignoreFailures = true
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

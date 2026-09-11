package com.openai.snapo.gradle

import org.gradle.api.Plugin
import org.gradle.api.initialization.Settings
import java.net.URI

/** Declares Node downloads in settings so consumers can forbid project repositories. */
class InspectorSettingsPlugin : Plugin<Settings> {
    override fun apply(settings: Settings) {
        settings.dependencyResolutionManagement.repositories.ivy {
            name = "SnapO Node.js"
            url = URI("https://nodejs.org/dist/")
            patternLayout { artifact("v[revision]/[artifact](-v[revision]-[classifier]).[ext]") }
            metadataSources { artifact() }
            content { includeModule("org.nodejs", "node") }
        }
    }
}

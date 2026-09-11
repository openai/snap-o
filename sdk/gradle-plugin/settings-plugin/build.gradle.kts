plugins { `kotlin-dsl` }

repositories { mavenCentral() }

gradlePlugin {
    plugins {
        register("snapoPluginSettings") {
            id = "com.openai.snapo.plugin-settings"
            implementationClass = "com.openai.snapo.gradle.PluginSettingsPlugin"
            displayName = "Snap-O tool settings"
            description = project.description
        }
    }
}

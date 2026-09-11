plugins { `kotlin-dsl` }

repositories { mavenCentral() }

gradlePlugin {
    plugins {
        register("snapoInspectorSettings") {
            id = "com.openai.snapo.inspector-settings"
            implementationClass = "com.openai.snapo.gradle.InspectorSettingsPlugin"
            displayName = "Snap-O inspector settings"
            description = project.description
        }
    }
}

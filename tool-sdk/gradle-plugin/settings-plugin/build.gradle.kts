plugins { `kotlin-dsl` }

repositories { mavenCentral() }

gradlePlugin {
    plugins {
        register("snapoToolSettings") {
            id = "com.openai.snapo.tool-settings"
            implementationClass = "com.openai.snapo.gradle.ToolSettingsPlugin"
            displayName = "Snap-O tool settings"
            description = project.description
        }
    }
}

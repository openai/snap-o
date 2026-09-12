pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

rootProject.name = "snapo-tool-gradle-plugin"

include(":settings-plugin")
project(":settings-plugin").name = "snapo-tool-settings-gradle-plugin"

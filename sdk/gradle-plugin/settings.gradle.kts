pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

rootProject.name = "snapo-plugin-gradle-plugin"

include(":settings-plugin")
project(":settings-plugin").name = "snapo-plugin-settings-gradle-plugin"

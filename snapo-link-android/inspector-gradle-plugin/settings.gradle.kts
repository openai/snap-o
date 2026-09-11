pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

rootProject.name = "snapo-inspector-gradle-plugin"

include(":settings-plugin")
project(":settings-plugin").name = "snapo-inspector-settings-gradle-plugin"

pluginManagement {
    includeBuild("build-logic")
    includeBuild("sdk/gradle-plugin")
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("com.openai.snapo.plugin-settings")
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "snap-o"
include(":plugin-runtime")
include(":tweaks-core")
include(":tweaks-core-noop")
include(":tweaks-views")
include(":tweaks")
include(":tweaks-noop")
include(":tweaks-overlay")
include(":tweaks-overlay-noop")
include(":network")
include(":network-okhttp3")
include(":network-okhttp3-noop")
include(":network-httpurlconnection")
include(":network-httpurlconnection-noop")
include(":samples:demo-tweaks")
include(":samples:demo-tweaks-views")
include(":samples:demo-okhttp")
include(":samples:demo-ktor-okhttp")
include(":samples:demo-httpurlconnection")
include(":samples:demo-shared")

// Group implementations without changing published Android artifact names.
project(":network").projectDir = file("plugins/network/android/core")
project(":network-okhttp3").projectDir = file("plugins/network/android/okhttp3")
project(":network-okhttp3-noop").projectDir = file("plugins/network/android/okhttp3-noop")
project(":network-httpurlconnection").projectDir = file("plugins/network/android/httpurlconnection")
project(":network-httpurlconnection-noop").projectDir = file("plugins/network/android/httpurlconnection-noop")
project(":tweaks").projectDir = file("plugins/tweaks/android/compose")
project(":tweaks-core").projectDir = file("plugins/tweaks/android/core")
project(":tweaks-core-noop").projectDir = file("plugins/tweaks/android/core-noop")
project(":tweaks-noop").projectDir = file("plugins/tweaks/android/noop")
project(":tweaks-overlay").projectDir = file("plugins/tweaks/android/overlay")
project(":tweaks-overlay-noop").projectDir = file("plugins/tweaks/android/overlay-noop")
project(":tweaks-views").projectDir = file("plugins/tweaks/android/views")
project(":plugin-runtime").projectDir = file("sdk/runtime")

project(":samples").projectDir = file("examples/android")

project(":samples:demo-httpurlconnection").projectDir = file("examples/android/demo-httpurlconnection")
project(":samples:demo-ktor-okhttp").projectDir = file("examples/android/demo-ktor-okhttp")
project(":samples:demo-okhttp").projectDir = file("examples/android/demo-okhttp")
project(":samples:demo-shared").projectDir = file("examples/android/demo-shared")
project(":samples:demo-tweaks").projectDir = file("examples/android/demo-tweaks")
project(":samples:demo-tweaks-views").projectDir = file("examples/android/demo-tweaks-views")

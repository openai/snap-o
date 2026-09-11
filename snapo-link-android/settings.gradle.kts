pluginManagement {
    includeBuild("build-logic")
    includeBuild("inspector-gradle-plugin")
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
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        ivy {
            name = "Node.js"
            url = uri("https://nodejs.org/dist/")
            patternLayout {
                artifact("v[revision]/[artifact](-v[revision]-[classifier]).[ext]")
            }
            metadataSources { artifact() }
            content { includeModule("org.nodejs", "node") }
        }
    }
}

rootProject.name = "snapo-link-android"
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

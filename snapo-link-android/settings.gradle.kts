pluginManagement {
    includeBuild("build-logic")
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
    }
}

rootProject.name = "snapo-link-android"
include(":link-core")
include(":network")
include(":network-okhttp3")
include(":network-okhttp3-noop")
include(":network-httpurlconnection")
include(":network-httpurlconnection-noop")
include(":samples:demo-okhttp")
include(":samples:demo-ktor-okhttp")
include(":samples:demo-httpurlconnection")

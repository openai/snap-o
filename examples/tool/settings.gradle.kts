pluginManagement {
    repositories {
        providers.gradleProperty("snapoRepository").orNull?.let { stagedRepository ->
            exclusiveContent {
                forRepository { maven { url = uri(stagedRepository) } }
                filter { includeGroupByRegex("com\\.openai\\.snapo(\\..*)?") }
            }
        }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("com.openai.snapo.tool-packager") version providers.gradleProperty("snapoVersion").get()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        providers.gradleProperty("snapoRepository").orNull?.let { stagedRepository ->
            exclusiveContent {
                forRepository { maven { url = uri(stagedRepository) } }
                filter { includeGroup(providers.gradleProperty("snapoGroup").get()) }
            }
        }
        google()
        mavenCentral()
    }
}

rootProject.name = "snapo-example"
include(":app", ":example-tool")

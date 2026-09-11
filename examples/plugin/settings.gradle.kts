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
        id("com.openai.snapo.plugin") version providers.gradleProperty("snapoVersion").get()
        id("com.openai.snapo.plugin-settings") version providers.gradleProperty("snapoVersion").get()
    }
}

plugins {
    id("com.openai.snapo.plugin-settings")
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

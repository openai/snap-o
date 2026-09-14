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
        ivy {
            name = "Node.js"
            url = uri("https://nodejs.org/dist/")
            patternLayout { artifact("v[revision]/[artifact](-v[revision]-[classifier]).[ext]") }
            metadataSources { artifact() }
            content { includeModule("org.nodejs", "node") }
        }
    }
}

rootProject.name = "snapo-example"
include(":app", ":example-tool")

// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlinx.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

group = providers.gradleProperty("GROUP").orNull ?: error("Missing GROUP property")

val versionFile = rootDir.resolve(
    providers.gradleProperty("VERSION_FILE").orNull
        ?: error("Missing VERSION_FILE property"),
)
require(versionFile.exists()) {
    "Missing VERSION file at ${versionFile.absolutePath}"
}

fun parseVersion(contents: String): String {
    val entries = contents.lineSequence()
        .map { it.trim() }
        .filter { line ->
            line.isNotEmpty() &&
                    !line.startsWith("#") &&
                    line.contains('=')
        }
        .map { line ->
            val (key, value) = line.split("=", limit = 2)
                .map(String::trim)
            key to value
        }
        .toMap()
    return entries["VERSION"] ?: error("VERSION entry not found in VERSION file")
}

val resolvedVersion = parseVersion(versionFile.readText())

version = resolvedVersion

subprojects {
    group = rootProject.group
    version = rootProject.version
}

import io.gitlab.arturbosch.detekt.Detekt
import org.gradle.api.provider.Property
import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.jetbrains.compose.desktop.application.tasks.AbstractJLinkTask
import java.io.File

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.composeHotReload)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlinx.serialization)
    alias(libs.plugins.detekt)
    alias(libs.plugins.metro)
}

repositories {
    mavenCentral()
    google()
    // Compose plugin artifacts.
    maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
}

kotlin {
    sourceSets {
        named("main") {
            kotlin.srcDir(layout.buildDirectory.dir("generated/version"))
        }
    }
}

data class VersionInfo(
    val version: String,
    val buildNumber: String,
)

fun readVersionInfo(versionFile: File): VersionInfo {
    if (!versionFile.exists()) {
        throw GradleException("VERSION file not found at ${versionFile.absolutePath}")
    }
    val entries = versionFile.readLines()
        .mapNotNull { line ->
            val trimmed = line.trim()
            if (trimmed.isBlank() || trimmed.startsWith("#")) return@mapNotNull null
            val parts = trimmed.split("=", limit = 2)
            if (parts.size != 2) return@mapNotNull null
            parts[0].trim() to parts[1].trim()
        }
        .toMap()
    val version = entries["VERSION"]
        ?: throw GradleException("VERSION entry missing in ${versionFile.absolutePath}")
    val buildNumber = entries["BUILD_NUMBER"]
        ?: throw GradleException("BUILD_NUMBER entry missing in ${versionFile.absolutePath}")
    return VersionInfo(version = version, buildNumber = buildNumber)
}

val versionInfo = readVersionInfo(rootProject.file("../VERSION"))
version = versionInfo.version
val resolvedPackageVersion = run {
    fun isValidPackageVersion(value: String): Boolean {
        if (!value.matches(Regex("\\d+(\\.\\d+){0,2}"))) return false
        val parts = value.split(".")
        val major = parts.firstOrNull()?.toIntOrNull() ?: return false
        if (major <= 0) return false
        return parts.drop(1).all { it.toIntOrNull()?.let { number -> number >= 0 } == true }
    }

    when {
        isValidPackageVersion(versionInfo.version) -> versionInfo.version
        isValidPackageVersion(versionInfo.buildNumber) -> versionInfo.buildNumber
        else -> "1.0.0"
    }
}
val generatedVersionDir = layout.buildDirectory.dir("generated/version")
val generateBuildInfo by tasks.registering {
    inputs.file(rootProject.file("../VERSION"))
    outputs.dir(generatedVersionDir)
    doLast {
        val outputDir = generatedVersionDir.get().asFile
        val outputFile = File(outputDir, "com/openai/snapo/desktop/BuildInfo.kt")
        outputFile.parentFile.mkdirs()
        outputFile.writeText(
            """
            package com.openai.snapo.desktop

            internal object BuildInfo {
                const val VERSION = "${versionInfo.version}"
                const val BUILD_NUMBER = "${versionInfo.buildNumber}"
            }
            """.trimIndent() + "\n"
        )
    }
}

val releaseDistributionTasks = setOf(
    "createReleaseDistributable",
    "runReleaseDistributable",
    "packageReleaseDistributionForCurrentOS",
    "packageReleaseDmg",
    "packageReleaseUberJarForCurrentOS",
    "notarizeReleaseDmg",
)
val isReleaseDistribution = gradle.startParameter.taskNames.any { taskName ->
    releaseDistributionTasks.contains(taskName.substringAfterLast(":"))
}

tasks.withType<AbstractJLinkTask>().configureEach {
    // Compose's public DSL doesn't currently expose `jlink --compress`.
    // We enable Constant String Sharing (--compress=1) to reduce the runtime image size while
    // staying friendly to DMG compression.
    @Suppress("UNCHECKED_CAST")
    val compressionLevel = javaClass.getMethod("getCompressionLevel\$compose")
        .invoke(this) as Property<Any?>
    val compressionValue = Class.forName("org.jetbrains.compose.desktop.application.internal.RuntimeCompressionLevel")
        .getField("CONSTANT_STRING_SHARING")
        .get(null)
    compressionLevel.set(compressionValue)
}

tasks.named("compileKotlin") {
    dependsOn(generateBuildInfo)
}

dependencies {
    detektPlugins(libs.detekt.formatting)
    detektPlugins(libs.detekt.compose.rules)

    implementation(compose.desktop.currentOs) {
        // Prevent accidental Material 2 usage in the desktop UI.
        exclude(group = "androidx.compose.material")
        exclude(group = "org.jetbrains.compose.material")
    }
    // Keep Material3 aligned with the Compose Multiplatform release notes (may differ from compose.material3).
    implementation(libs.compose.material3)
    // Compose Multiplatform resource system (replaces deprecated `painterResource("path")`).
    implementation(libs.compose.components.resources)
    implementation(libs.compose.components.splitpane)
    implementation(libs.compose.ui.tooling.preview)

    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.serialization.json)
    implementation(libs.clikt)
}

compose.resources {
    // Keep the generated Res class in a predictable package.
    packageOfResClass = "com.openai.snapo.desktop.generated.resources"
}

detekt {
    toolVersion = libs.versions.detekt.get()
    buildUponDefaultConfig = true
    autoCorrect = true
    config.setFrom(file("config/detekt/detekt.yml"))
    ignoreFailures = false
}

tasks.withType<Detekt>().configureEach {
    jvmTarget = "17"
    reports.apply {
        sarif.required.set(false)
        txt.required.set(false)
        xml.required.set(false)
        md.required.set(false)
        html.required.set(true)
    }
}

compose.desktop {
    application {
        mainClass = "com.openai.snapo.desktop.MainKt"
        jvmArgs("-Dapple.awt.application.appearance=system")

        nativeDistributions {
            // macOS-only for now (per requirements).
            targetFormats(TargetFormat.Dmg)
            includeAllModules = false
            // Suggested by `./gradlew suggestRuntimeModules` for this app.
            modules("java.instrument", "jdk.unsupported", "java.net.http", "java.xml")
            packageName = "Snap-O Network Inspector"
            packageVersion = resolvedPackageVersion
            macOS {
                packageBuildVersion = versionInfo.buildNumber
                iconFile.set(project.file("src/main/resources/icons/network.icns"))
                if (isReleaseDistribution) {
                    entitlementsFile.set(project.file("macos/NetworkInspector.entitlements"))
                    runtimeEntitlementsFile.set(project.file("macos/NetworkInspector.entitlements"))
                }
            }
        }

        buildTypes {
            release {
                proguard {
                    // Slightly reduces startup overhead (fewer jars to scan/load) and can shave a
                    // bit of size from the final bundle.
                    joinOutputJars.set(true)
                    configurationFiles.from(file("proguard-rules.pro"))
                }
            }
        }
    }
}

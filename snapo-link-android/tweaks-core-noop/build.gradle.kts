plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "No-op Compose-free tweaks for release builds."

android { namespace = "com.openai.snapo.tweaks.core" }

dependencies {
    api(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.annotation)
    testImplementation(libs.junit4)
    testImplementation(libs.kotlinx.coroutines.test)
}

val verifyNoComposeDependencies by tasks.registering {
    group = "verification"
    description = "Checks that the core has no Compose dependencies."
    doLast {
        listOf("debugRuntimeClasspath", "releaseRuntimeClasspath").forEach { name ->
            val compose = configurations.getByName(name).incoming.resolutionResult.allComponents
                .mapNotNull { it.moduleVersion }
                .filter { it.group.startsWith("androidx.compose") }
            check(compose.isEmpty()) { "$name includes Compose: $compose" }
        }
    }
}

tasks.named("check") { dependsOn(verifyNoComposeDependencies) }

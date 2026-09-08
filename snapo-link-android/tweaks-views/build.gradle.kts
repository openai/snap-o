plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "View bindings for Snap-O tweak values."

android { namespace = "com.openai.snapo.tweaks.views" }

dependencies {
    api(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.annotation)
}

val verifyNoComposeDependencies by tasks.registering {
    group = "verification"
    description = "Checks that the View bindings have no Compose dependencies."
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

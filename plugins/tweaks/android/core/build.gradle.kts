plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    id("com.openai.snapo.plugin")
}

description = "Compose-free live tweaks for Snap-O."

android { namespace = "com.openai.snapo.tweaks.core" }

snapoPlugin {
    frontendDirectory = layout.projectDirectory.dir("../../frontend")
    id = "tweaks"
    displayName = "Tweaks"
    protocolVersion = 7
    icon = "@drawable/snapo_tweaks_inspector_icon"
}

dependencies {
    implementation(project(":plugin-runtime"))
    api(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.annotation)
    testImplementation(libs.androidx.lifecycle.viewmodel)
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

// These first-party frontends use the SDK checkout while external tools use an npm package.
tasks.named("pluginBuild") {
    inputs.dir(rootProject.file("sdk/host/src"))
    inputs.file(rootProject.file("sdk/host/tsconfig.build.json"))
}

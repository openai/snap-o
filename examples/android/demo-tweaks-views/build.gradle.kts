plugins {
    id("snapo.android.application")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.demo.tweaks.views"
    defaultConfig {
        applicationId = "com.openai.snapo.demo.tweaks.views"
        versionCode = 1
        versionName = "1.0"
    }
}

val useNoop = providers.gradleProperty("snapo.samples.noop")
    .map(String::toBooleanStrict)
    .getOrElse(false)

dependencies {
    implementation(libs.androidx.activity.ktx)
    implementation(libs.androidx.lifecycle.viewmodel)
    implementation(project(":tweaks-views"))
    debugImplementation(project(if (useNoop) ":tweaks-core-noop" else ":tweaks-core"))
    releaseImplementation(project(":tweaks-core-noop"))
}

val verifyNoComposeRuntime by tasks.registering {
    group = "verification"
    description = "Checks that the libraries and sample have no Compose runtime or UI."
    dependsOn(
        ":tweaks-core:verifyNoComposeDependencies",
        ":tweaks-core-noop:verifyNoComposeDependencies",
        ":tweaks-views:verifyNoComposeDependencies",
    )
    doLast {
        // AndroidX Activity uses standalone annotations without the Compose runtime.
        val standaloneAnnotations = setOf("runtime-annotation", "runtime-annotation-android")
        listOf("debugRuntimeClasspath", "releaseRuntimeClasspath").forEach { name ->
            val compose = configurations.getByName(name).incoming.resolutionResult.allComponents
                .mapNotNull { it.moduleVersion }
                .filter { it.group.startsWith("androidx.compose") && it.name !in standaloneAnnotations }
            check(compose.isEmpty()) { "$name includes Compose: $compose" }
        }
    }
}

tasks.named("check") { dependsOn(verifyNoComposeRuntime) }

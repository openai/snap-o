plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    id("com.openai.snapo.tool-packager")
    alias(libs.plugins.kotlinx.serialization)
}

description = "Shared Android components used by Snap-O network inspection integrations."

android {
    namespace = "com.openai.snapo.network"
}

// This build declares the Node repository in settings.gradle.kts.
node { distBaseUrl.set(null as String?) }

snapoTool {
    frontendDirectory = layout.projectDirectory.dir("../../frontend")
    id = "network"
    displayName = "Network"
    icon = "@drawable/snapo_network_inspector_icon"
}

dependencies {
    implementation(project(":tool-core"))
    api(libs.kotlinx.coroutines.core)
    api(libs.serialization.core)

    implementation(libs.androidx.core.ktx)
    implementation(libs.serialization.json)
    testImplementation(libs.junit4)
}

// Include sources outside each frontend directory in incremental builds.
tasks.named("buildSnapoToolFrontend") {
    inputs.dir(rootProject.file("tools/frontend"))
    inputs.dir(rootProject.file("tool-sdk/host/src"))
    inputs.file(rootProject.file("tool-sdk/host/tsconfig.build.json"))
}

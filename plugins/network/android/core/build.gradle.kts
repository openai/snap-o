plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    id("com.openai.snapo.plugin")
    alias(libs.plugins.kotlinx.serialization)
}

description = "Shared Android components used by Snap-O network inspection integrations."

android {
    namespace = "com.openai.snapo.network"
}

snapoPlugin {
    frontendDirectory = layout.projectDirectory.dir("../../frontend")
    id = "network"
    displayName = "Network"
    protocolVersion = 3
    icon = "@drawable/snapo_network_inspector_icon"
}

dependencies {
    implementation(project(":plugin-runtime"))
    api(libs.kotlinx.coroutines.core)
    api(libs.serialization.core)

    implementation(libs.androidx.core.ktx)
    implementation(libs.serialization.json)
    testImplementation(libs.junit4)
}

// These first-party frontends use the SDK checkout while external tools use an npm package.
tasks.named("pluginBuild") {
    inputs.dir(rootProject.file("sdk/host/src"))
    inputs.file(rootProject.file("sdk/host/tsconfig.build.json"))
}

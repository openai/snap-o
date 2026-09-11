plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    id("com.openai.snapo.inspector")
    alias(libs.plugins.kotlinx.serialization)
}

description = "Shared Android components used by Snap-O network inspection integrations."

android {
    namespace = "com.openai.snapo.network"
}

snapoInspector {
    id = "network"
    displayName = "Network"
    protocolVersion = 3
    icon = "@drawable/snapo_network_inspector_icon"
}

dependencies {
    implementation(project(":inspector-runtime"))
    api(libs.kotlinx.coroutines.core)
    api(libs.serialization.core)

    implementation(libs.androidx.core.ktx)
    implementation(libs.serialization.json)
    testImplementation(libs.junit4)
}

// These first-party frontends use the SDK checkout while external tools use an npm package.
tasks.named("inspectorBuild") {
    inputs.dir(rootProject.file("../inspectors/host-sdk/src"))
    inputs.file(rootProject.file("../inspectors/host-sdk/tsconfig.build.json"))
}

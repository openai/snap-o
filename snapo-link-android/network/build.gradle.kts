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
    api(libs.kotlinx.coroutines.core)
    api(libs.serialization.core)

    implementation(libs.androidx.core.ktx)
    implementation(libs.serialization.json)
    testImplementation(libs.junit4)
}

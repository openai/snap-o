plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

description = "Live Compose tweaks for inspecting and adjusting a running app with Snap-O."

android {
    namespace = "com.openai.snapo.tweaks"

    buildFeatures {
        compose = true
    }
}

dependencies {
    api(platform(libs.androidx.compose.bom))
    api("androidx.compose.runtime:runtime")
    api(libs.androidx.compose.ui.graphics)
    api(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit4)
}

plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

description = "No-op Compose tweaks for excluding Snap-O live adjustments from release builds."

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
}

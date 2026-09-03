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
    api(libs.androidx.compose.runtime)
    api(libs.androidx.compose.ui.graphics)
    api(libs.kotlinx.coroutines.core)
}

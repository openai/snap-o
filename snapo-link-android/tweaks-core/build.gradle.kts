plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

description = "Shared implementation for Snap-O tweaks."

android {
    namespace = "com.openai.snapo.tweaks.core"

    buildFeatures {
        compose = true
    }
}

dependencies {
    api(libs.androidx.compose.runtime)
    api(libs.androidx.compose.ui.graphics)
    api(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit4)
}

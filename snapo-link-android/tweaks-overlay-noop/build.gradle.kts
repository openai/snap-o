plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

description = "No-op Compose tweak overlay for excluding the floating inspector from release builds."

android {
    namespace = "com.openai.snapo.tweaks.overlay"

    buildFeatures {
        compose = true
    }
}

dependencies {
    api(libs.androidx.compose.runtime)
    api(libs.androidx.compose.ui)
}

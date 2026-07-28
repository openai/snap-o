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
    api(platform(libs.androidx.compose.bom))
    api(libs.androidx.compose.ui)

    implementation(libs.androidx.compose.foundation)
}

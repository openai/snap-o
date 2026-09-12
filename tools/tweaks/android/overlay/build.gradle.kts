plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

description = "Optional in-app Compose overlay for inspecting and adjusting Snap-O Tweaks."

android {
    namespace = "com.openai.snapo.tweaks.overlay"

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(project(":tweaks"))

    api(libs.androidx.compose.runtime)
    api(libs.androidx.compose.ui)

    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    // Preserve the ripple version previously selected by the Compose BOM.
    implementation(libs.androidx.compose.material.ripple)
    implementation(libs.androidx.core.ktx)

    testImplementation(libs.junit4)
}

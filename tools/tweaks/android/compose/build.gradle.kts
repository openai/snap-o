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

    testOptions.unitTests.isIncludeAndroidResources = true
}

dependencies {
    api(libs.androidx.compose.runtime)
    api(libs.androidx.compose.ui.graphics)
    api(project(":tweaks-core"))

    testImplementation(libs.junit4)
    testImplementation(libs.androidx.compose.ui.test.junit4)
    testImplementation(libs.robolectric)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

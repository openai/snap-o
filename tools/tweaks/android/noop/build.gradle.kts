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

    testOptions.unitTests.isIncludeAndroidResources = true
}

dependencies {
    api(libs.androidx.compose.runtime)
    api(libs.androidx.compose.ui.graphics)
    api(project(":tweaks-core-noop"))

    testImplementation(libs.junit4)
    testImplementation(libs.androidx.compose.ui.test.junit4)
    testImplementation(libs.robolectric)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

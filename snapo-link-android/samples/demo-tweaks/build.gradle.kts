plugins {
    id("snapo.android.application")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.openai.snapo.demo.tweaks"

    defaultConfig {
        applicationId = "com.openai.snapo.demo.tweaks"
        versionCode = 1
        versionName = "1.0"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)

    debugImplementation(project(":tweaks"))
    debugImplementation(project(":tweaks-overlay"))
    releaseImplementation(project(":tweaks-noop"))
    releaseImplementation(project(":tweaks-overlay-noop"))
}

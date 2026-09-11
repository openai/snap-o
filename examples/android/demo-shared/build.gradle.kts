plugins {
    id("snapo.android.library")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlinx.serialization)
}

android {
    namespace = "com.openai.snapo.demo.shared"

    buildFeatures {
        compose = true
    }
}

dependencies {
    api(libs.androidx.lifecycle.viewmodel)
    api(libs.androidx.lifecycle.viewmodel.savedstate)
    api(libs.androidx.compose.runtime)
    api(libs.kotlinx.coroutines.core)
    api(libs.serialization.core)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(platform(libs.okhttp3.bom))
    implementation(libs.okhttp3.okhttp)
    implementation(libs.okhttp3.mockwebserver3)
}

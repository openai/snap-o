plugins {
    id("snapo.android.application")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.openai.snapo.demo"

    defaultConfig {
        applicationId = "com.openai.snapo.demo"
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)

    implementation(platform(libs.okhttp3.bom))
    implementation(libs.okhttp3.okhttp)
    implementation(libs.okhttp3.coroutines)
    implementation(libs.okhttp3.mockwebserver3)

    debugImplementation(project(":network-okhttp3"))
    releaseImplementation(project(":network-okhttp3-noop"))
}

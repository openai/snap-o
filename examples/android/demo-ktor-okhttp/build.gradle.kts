plugins {
    id("snapo.android.application")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.openai.snapo.demo.ktor"

    defaultConfig {
        applicationId = "com.openai.snapo.demo.ktor"
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }
}

val useNoop = providers.gradleProperty("snapo.samples.noop")
    .map(String::toBooleanStrict)
    .getOrElse(false)

dependencies {

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.activity.ktx)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)

    implementation(platform(libs.okhttp3.bom))
    implementation(libs.okhttp3.okhttp)
    implementation(libs.okhttp3.coroutines)

    implementation(libs.ktor.client.core)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.ktor.client.websockets)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.serialization.kotlinx.json)
    implementation(libs.serialization.json)
    implementation(project(":samples:demo-shared"))

    debugImplementation(project(if (useNoop) ":network-okhttp3-noop" else ":network-okhttp3"))
    releaseImplementation(project(":network-okhttp3-noop"))
}

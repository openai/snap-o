plugins {
    id("snapo.android.application")
    id("snapo.detekt")
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.openai.snapo.demo.httpurlconnection"

    defaultConfig {
        applicationId = "com.openai.snapo.demo.httpurlconnection"
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
    implementation(project(":samples:demo-shared"))
    implementation(libs.serialization.json)

    debugImplementation(project(if (useNoop) ":network-httpurlconnection-noop" else ":network-httpurlconnection"))
    releaseImplementation(project(":network-httpurlconnection-noop"))
}

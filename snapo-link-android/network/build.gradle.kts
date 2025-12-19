plugins {
    id("snapo.android.library")
    id("snapo.detekt")
    alias(libs.plugins.kotlinx.serialization)
}

android {
    namespace = "com.openai.snapo.network"
}

dependencies {
    implementation(project(":link-core"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.serialization.json)
}

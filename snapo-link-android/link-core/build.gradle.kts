plugins {
    id("snapo.android.library")
    id("snapo.detekt")
    alias(libs.plugins.kotlinx.serialization)
}

android {
    namespace = "com.openai.snapo.link.core"
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.serialization.json)
}

plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "No-op OkHttp integration for disabling Snap-O network interception in release builds."

android {
    namespace = "com.openai.snapo.network.okhttp3"
}

dependencies {
    api(platform(libs.okhttp3.bom))
    api(libs.okhttp3.okhttp)
    api(libs.kotlinx.coroutines.core)
}

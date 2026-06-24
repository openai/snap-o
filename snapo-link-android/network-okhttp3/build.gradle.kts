plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "OkHttp integration for intercepting network requests with Snap-O."

android {
    namespace = "com.openai.snapo.network.okhttp3"
}

dependencies {
    implementation(project(":network"))
    api(platform(libs.okhttp3.bom))
    api(libs.okhttp3.okhttp)
    api(libs.kotlinx.coroutines.core)
}

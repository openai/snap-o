plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "HttpURLConnection integration for intercepting network requests with Snap-O."

android {
    namespace = "com.openai.snapo.network.httpurlconnection"
}

dependencies {
    implementation(project(":network"))
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit4)
}

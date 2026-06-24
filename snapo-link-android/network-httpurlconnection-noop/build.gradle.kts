plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "No-op HttpURLConnection integration for disabling Snap-O network interception in release builds."

android {
    namespace = "com.openai.snapo.network.httpurlconnection"
}

dependencies {
    api(libs.kotlinx.coroutines.core)
}

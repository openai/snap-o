plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.network.httpurlconnection"
}

dependencies {
    api(libs.kotlinx.coroutines.core)
}

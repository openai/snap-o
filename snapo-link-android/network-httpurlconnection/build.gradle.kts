plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.network.httpurlconnection"
}

dependencies {
    implementation(project(":network"))
    api(libs.kotlinx.coroutines.core)
}

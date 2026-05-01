plugins {
    id("snapo.android.library")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.network.httpurlconnection"
}

dependencies {
    implementation(project(":network"))
    implementation(libs.kotlinx.coroutines.core)
}

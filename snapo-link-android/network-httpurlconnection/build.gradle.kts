plugins {
    id("snapo.android.library")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.network.httpurlconnection"
}

dependencies {
    api(project(":link-core"))
    implementation(project(":network"))
    implementation(libs.kotlinx.coroutines.core)
}

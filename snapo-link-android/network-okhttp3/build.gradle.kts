plugins {
    id("snapo.android.library")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.network.okhttp3"
}

dependencies {
    api(project(":link-core"))
    implementation(project(":network"))
    implementation(platform(libs.okhttp3.bom))
    implementation(libs.okhttp3.okhttp)
    implementation(libs.kotlinx.coroutines.core)
}

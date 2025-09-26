plugins {
    id("snapo.android.library")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.link.okhttp3"
}

dependencies {
    api(project(":link-core"))
    implementation(platform(libs.okhttp3.bom))
    implementation(libs.okhttp3.okhttp)
    implementation(libs.kotlinx.coroutines.core)
}

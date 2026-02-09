plugins {
    id("snapo.android.library")
    id("snapo.detekt")
}

android {
    namespace = "com.openai.snapo.demo.shared"
}

dependencies {
    implementation(platform(libs.okhttp3.bom))
    implementation(libs.okhttp3.okhttp)
    implementation(libs.okhttp3.mockwebserver3)
}

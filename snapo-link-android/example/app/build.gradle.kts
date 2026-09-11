plugins { id("com.android.application") }

android {
    namespace = "com.example.snapo"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.example.snapo"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }
}

dependencies {
    debugImplementation(project(":example-tool"))
}

plugins {
    id("com.android.library")
    id("com.openai.snapo.plugin")
}

android {
    namespace = "com.example.snapo.tool"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
}

snapoPlugin {
    id = "example"
    displayName = "Example"
    protocolVersion = 1
}

dependencies {
    implementation("androidx.startup:startup-runtime:1.2.0")
    implementation("${providers.gradleProperty("snapoGroup").get()}:plugin-runtime:${providers.gradleProperty("snapoVersion").get()}")
    testImplementation("junit:junit:4.13.2")
}

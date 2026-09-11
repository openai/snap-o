plugins {
    id("com.android.library")
    id("com.openai.snapo.inspector")
}

android {
    namespace = "com.example.snapo.tool"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
}

snapoInspector {
    id = "example"
    displayName = "Example"
    protocolVersion = 1
}

dependencies {
    implementation("${providers.gradleProperty("snapoGroup").get()}:inspector-runtime:${providers.gradleProperty("snapoVersion").get()}")
    testImplementation("junit:junit:4.13.2")
}

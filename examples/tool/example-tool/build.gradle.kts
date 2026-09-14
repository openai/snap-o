plugins {
    id("com.android.library")
    id("com.openai.snapo.tool-packager")
}

android {
    namespace = "com.example.snapo.tool"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
}

// This build declares the Node repository in settings.gradle.kts.
node { distBaseUrl.set(null as String?) }

snapoTool {
    id = "example"
    displayName = "Example"
    icon = "@drawable/example_tool_icon"
}

dependencies {
    implementation("androidx.startup:startup-runtime:1.2.0")
    implementation("${providers.gradleProperty("snapoGroup").get()}:tool-core:${providers.gradleProperty("snapoVersion").get()}")
    testImplementation("junit:junit:4.13.2")
}

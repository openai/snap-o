plugins {
    id("com.android.library")
    id("com.openai.snapo.tool")
}

android {
    namespace = "com.example.snapo.tool"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
}

snapoTool {
    id = "example"
    displayName = "Example"
    icon = "@drawable/example_tool_icon"
}

dependencies {
    implementation("androidx.startup:startup-runtime:1.2.0")
    implementation("${providers.gradleProperty("snapoGroup").get()}:tool-runtime:${providers.gradleProperty("snapoVersion").get()}")
    testImplementation("junit:junit:4.13.2")
}

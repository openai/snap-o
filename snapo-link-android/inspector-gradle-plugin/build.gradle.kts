plugins {
    `kotlin-dsl`
}

group = "com.openai.snapo"

repositories {
    google()
    mavenCentral()
    gradlePluginPortal()
}

dependencies {
    compileOnly("com.android.tools.build:gradle-api:9.0.0")
    implementation("com.github.node-gradle:gradle-node-plugin:7.1.0")
}

gradlePlugin {
    plugins {
        register("snapoInspector") {
            id = "com.openai.snapo.inspector"
            implementationClass = "com.openai.snapo.gradle.InspectorPlugin"
        }
    }
}

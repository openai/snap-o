plugins {
    `kotlin-dsl`
    alias(libs.plugins.projectAccessors)
}

group = "com.openai.snapo.buildlogic"

dependencies {
    implementation(libs.gradle)
    implementation(libs.kotlin.gradle.plugin)
    implementation(libs.detekt.gradle.plugin)
}

gradlePlugin {
    plugins {
        register("snapoAndroidLibrary") {
            id = "snapo.android.library"
            implementationClass = "com.openai.snapo.buildlogic.android.AndroidLibraryConventionPlugin"
        }
        register("snapoAndroidApplication") {
            id = "snapo.android.application"
            implementationClass = "com.openai.snapo.buildlogic.android.AndroidApplicationConventionPlugin"
        }
        register("snapoDetekt") {
            id = "snapo.detekt"
            implementationClass = "com.openai.snapo.buildlogic.quality.DetektConventionPlugin"
        }
    }
}

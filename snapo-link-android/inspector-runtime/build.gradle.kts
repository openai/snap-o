plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "Local socket and HTTP infrastructure for Snap-O Android inspectors."

android { namespace = "com.openai.snapo.inspector" }

dependencies {
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit4)
}

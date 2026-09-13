plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
}

description = "Local socket and HTTP infrastructure for Snap-O Android tools."

android { namespace = "com.openai.snapo.tool" }

dependencies {
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit4)
    testImplementation(libs.kotlinx.coroutines.test)
}

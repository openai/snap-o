import kotlinx.validation.KotlinApiBuildTask
import kotlinx.validation.KotlinApiCompareTask
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile

plugins {
    id("snapo.android.library")
    id("snapo.maven.publish")
    id("snapo.detekt")
    alias(libs.plugins.binary.compatibility.validator)
}

description = "Local socket and HTTP infrastructure for Snap-O Android tools."

android { namespace = "com.openai.snapo.tool" }

dependencies {
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.junit4)
    testImplementation(libs.kotlinx.coroutines.test)
    // BCV does not detect AGP 9's built-in Kotlin plugin to select this dependency.
    add("bcv-rt-jvm-cp", "org.jetbrains.kotlin:kotlin-metadata-jvm:${libs.versions.kotlin.get()}")
}

// Register BCV's standard tasks explicitly until it supports AGP 9's built-in Kotlin.
val apiBuild = tasks.register<KotlinApiBuildTask>("apiBuild") {
    inputClassesDirs.from(
        tasks.named<KotlinJvmCompile>("compileReleaseKotlin").flatMap { it.destinationDirectory },
        tasks.named<JavaCompile>("compileReleaseJavaWithJavac").flatMap { it.destinationDirectory },
    )
    runtimeClasspath.from(configurations.named("bcv-rt-jvm-cp-resolver"))
    outputApiFile.set(layout.buildDirectory.file("api/tool-core.api"))
}

val apiCheck = tasks.register<KotlinApiCompareTask>("apiCheck") {
    group = "verification"
    description = "Checks the tool-core public API against its reviewed baseline."
    projectApiFile.set(layout.projectDirectory.file("api/tool-core.api"))
    generatedApiFile.set(apiBuild.flatMap { it.outputApiFile })
    mustRunAfter("apiDump")
}

tasks.register<Copy>("apiDump") {
    group = "other"
    description = "Updates the tool-core public API baseline for review."
    from(apiBuild.flatMap { it.outputApiFile })
    into(layout.projectDirectory.dir("api"))
}

tasks.named("check") { dependsOn(apiCheck) }

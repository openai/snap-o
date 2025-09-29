// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlinx.serialization) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

group = providers.gradleProperty("GROUP").orNull ?: error("Missing GROUP property")

providers.gradleProperty("VERSION_NAME")
    .orElse(providers.gradleProperty("VERSION"))
    .orElse(providers.gradleProperty("version"))
    .orElse("0.0.1-SNAPSHOT")
    .map { resolved -> version = resolved }

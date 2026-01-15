package com.openai.snapo.desktop.adb

data class Device(
    val id: String,
    val model: String,
    val androidVersion: String,
    val vendorModel: String?,
    val manufacturer: String?,
    val avdName: String?,
) {
    val displayTitle: String
        get() = when {
            !avdName.isNullOrBlank() -> avdName
            !vendorModel.isNullOrBlank() -> vendorModel
            else -> model
        }
}

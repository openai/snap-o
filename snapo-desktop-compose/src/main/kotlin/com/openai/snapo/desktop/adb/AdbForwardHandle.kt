package com.openai.snapo.desktop.adb

data class AdbForwardHandle(
    val deviceId: String,
    val localPort: Int,
    val remote: String,
)

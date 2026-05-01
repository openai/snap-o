package com.openai.snapo.network

import kotlinx.serialization.Serializable

object SnapOMethod {
    const val AppInfo: String = "SnapO.appInfo"
    const val ReplayComplete: String = "SnapO.replayComplete"
}

@Serializable
data class SnapOAppInfoParams(
    val protocolVersion: Int,
    val packageName: String,
    val processName: String,
    val pid: Int,
    val serverStartWallMs: Long,
    val serverStartMonoNs: Long,
    val mode: String,
    val icon: SnapOAppIcon? = null,
)

@Serializable
data class SnapOAppIcon(
    val width: Int,
    val height: Int,
    val format: String = "png",
    val base64Data: String,
)

internal const val NetworkProtocolVersion: Int = 1

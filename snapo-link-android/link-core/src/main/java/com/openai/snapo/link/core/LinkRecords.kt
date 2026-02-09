@file:OptIn(ExperimentalSerializationApi::class)

package com.openai.snapo.link.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** Top-level records sent over the link. */
@Serializable
sealed interface LinkRecord

/** Emitted first on every connection. */
@Serializable
@SerialName("Hello")
data class Hello(
    @EncodeDefault(EncodeDefault.Mode.ALWAYS)
    val schemaVersion: Int = SchemaVersion,
    val packageName: String,
    val processName: String,
    val pid: Int,
    val serverStartWallMs: Long,
    val serverStartMonoNs: Long,
    val mode: String,
    val features: List<LinkFeatureInfo> = emptyList(),
) : LinkRecord

/** Optional icon metadata to help the desktop show the app branding. */
@Serializable
@SerialName("AppIcon")
data class AppIcon(
    val packageName: String,
    val width: Int,
    val height: Int,
    val format: String = "png",
    val base64Data: String,
) : LinkRecord

/** Marker after snapshot dump completes. */
@Serializable
@SerialName("ReplayComplete")
class ReplayComplete : LinkRecord

/** Wrapper for feature-specific payloads. */
@Serializable
@SerialName("FeatureEvent")
data class FeatureEvent(
    val feature: String,
    val payload: JsonElement,
) : LinkRecord

@Serializable
data class LinkFeatureInfo(
    val id: String,
)

internal const val SchemaVersion: Int = 3

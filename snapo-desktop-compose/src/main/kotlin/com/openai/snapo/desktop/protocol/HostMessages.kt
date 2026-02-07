package com.openai.snapo.desktop.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** Messages sent from the host (desktop) to the device link server. */
@Serializable
sealed interface HostMessage

/** Indicates a host feature UI window has opened for this connection. */
@Serializable
@SerialName("FeatureOpened")
data class FeatureOpened(
    val feature: String,
) : HostMessage

/** Sends a feature-specific command payload to the device. */
@Serializable
@SerialName("FeatureCommand")
data class FeatureCommand(
    val feature: String,
    val payload: JsonElement,
) : HostMessage

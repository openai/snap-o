package com.openai.snapo.link.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Messages sent from the host (desktop) to the device link server. */
@Serializable
sealed interface HostMessage

/** Indicates a host feature UI window has opened for this connection. */
@Serializable
@SerialName("FeatureOpened")
data class FeatureOpened(
    val feature: String,
) : HostMessage

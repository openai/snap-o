package com.openai.snapo.desktop.protocol

import kotlinx.serialization.json.Json

/**
 * Snap-O link uses newline-delimited JSON with a `type` discriminator.
 *
 * Keep this config aligned with the Android side (`com.openai.snapo.link.core.Ndjson`).
 */
val Ndjson: Json = Json {
    prettyPrint = false
    ignoreUnknownKeys = true
    encodeDefaults = false
    explicitNulls = false
    classDiscriminator = "type"
}

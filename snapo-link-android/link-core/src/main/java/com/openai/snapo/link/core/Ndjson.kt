package com.openai.snapo.link.core

import kotlinx.serialization.json.Json

internal val Ndjson = Json {
    prettyPrint = false
    ignoreUnknownKeys = true
    encodeDefaults = false
    explicitNulls = false
    classDiscriminator = "type"
}

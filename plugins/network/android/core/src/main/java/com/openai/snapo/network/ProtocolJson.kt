package com.openai.snapo.network

import kotlinx.serialization.json.Json

internal val ProtocolJson: Json = Json {
    prettyPrint = false
    ignoreUnknownKeys = true
    encodeDefaults = false
    explicitNulls = false
}

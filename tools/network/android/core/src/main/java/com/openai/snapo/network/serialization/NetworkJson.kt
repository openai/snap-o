package com.openai.snapo.network.serialization

import kotlinx.serialization.json.Json

internal val NetworkJson: Json = Json {
    prettyPrint = false
    ignoreUnknownKeys = true
    encodeDefaults = false
    explicitNulls = false
    classDiscriminator = "type"
}

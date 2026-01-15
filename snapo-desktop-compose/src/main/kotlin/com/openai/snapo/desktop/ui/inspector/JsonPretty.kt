package com.openai.snapo.desktop.ui.inspector

import com.openai.snapo.desktop.util.JsonOrderPreservingFormatter
import kotlinx.serialization.json.Json

internal fun prettyPrintedJsonOrNull(text: String): String? {
    return runCatching {
        Json.parseToJsonElement(text)
        formatJsonPreservingOrder(text)
    }.getOrNull()
}

internal fun formatJsonPreservingOrder(text: String): String {
    return JsonOrderPreservingFormatter.format(text)
}

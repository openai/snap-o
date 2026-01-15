package com.openai.snapo.desktop.ui.json

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

@Stable
class JsonOutlineExpansionState(
    private val initiallyExpanded: Boolean,
) {
    var expandedNodes by mutableStateOf(if (initiallyExpanded) setOf("$") else emptySet())
    var expandedStrings by mutableStateOf(emptySet<String>())
    private var lastPayloadKey: Int? = null

    fun sync(payloadKey: Int, rootId: String) {
        if (lastPayloadKey != payloadKey) {
            lastPayloadKey = payloadKey
            expandedNodes = if (initiallyExpanded) setOf(rootId) else emptySet()
            expandedStrings = emptySet()
        }
    }
}

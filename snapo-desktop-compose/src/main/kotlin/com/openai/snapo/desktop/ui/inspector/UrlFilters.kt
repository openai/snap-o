package com.openai.snapo.desktop.ui.inspector

import com.openai.snapo.desktop.inspector.NetworkInspectorListItemUiModel

internal fun filterItemsByUrlSearch(
    items: List<NetworkInspectorListItemUiModel>,
    searchText: String,
): List<NetworkInspectorListItemUiModel> {
    if (searchText.isBlank()) return items

    val tokens = parseUrlFilterTokens(searchText)
    if (tokens.includes.isEmpty() && tokens.excludes.isEmpty()) return items

    return items.filter { item ->
        val url = item.url
        val includesMatch = tokens.includes.all { url.contains(it, ignoreCase = true) }
        val excludesMatch = tokens.excludes.any { url.contains(it, ignoreCase = true) }
        includesMatch && !excludesMatch
    }
}

private data class UrlFilterTokens(
    val includes: List<String>,
    val excludes: List<String>,
)

private fun parseUrlFilterTokens(searchText: String): UrlFilterTokens {
    val includes = mutableListOf<String>()
    val excludes = mutableListOf<String>()

    searchText.split(Regex("\\s+"))
        .asSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .forEach { token ->
            if (token.startsWith("-")) {
                val value = token.drop(1)
                if (value.isNotBlank()) {
                    excludes.add(value)
                }
                return@forEach
            }
            includes.add(token)
        }

    return UrlFilterTokens(includes = includes, excludes = excludes)
}

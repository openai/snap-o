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

    tokenizeUrlSearch(searchText).forEach { token ->
        if (token.value.isBlank()) return@forEach
        if (token.isExcluded) {
            excludes.add(token.value)
        } else {
            includes.add(token.value)
        }
    }

    return UrlFilterTokens(includes = includes, excludes = excludes)
}

private data class UrlFilterToken(
    val value: String,
    val isExcluded: Boolean,
)

private fun tokenizeUrlSearch(searchText: String): List<UrlFilterToken> {
    val tokens = mutableListOf<UrlFilterToken>()
    var index = 0

    fun skipWhitespace() {
        while (index < searchText.length && searchText[index].isWhitespace()) {
            index++
        }
    }

    while (index < searchText.length) {
        skipWhitespace()
        if (index >= searchText.length) break

        var isExcluded = false
        if (searchText[index] == '-') {
            isExcluded = true
            index++
        }

        if (index >= searchText.length) break

        val value = if (searchText[index] == '"') {
            index++
            val builder = StringBuilder()
            while (index < searchText.length) {
                val current = searchText[index]
                if (current == '\\' && index + 1 < searchText.length) {
                    val next = searchText[index + 1]
                    when (next) {
                        '"', '\\' -> {
                            builder.append(next)
                            index += 2
                            continue
                        }
                    }
                }
                if (current == '"') {
                    index++
                    break
                }
                builder.append(current)
                index++
            }
            builder.toString()
        } else {
            val builder = StringBuilder()
            while (index < searchText.length && !searchText[index].isWhitespace()) {
                val current = searchText[index]
                if (current == '\\' && index + 1 < searchText.length) {
                    val next = searchText[index + 1]
                    when (next) {
                        '"', '\\', ' ', '\t', '\n' -> {
                            builder.append(next)
                            index += 2
                            continue
                        }
                    }
                }
                builder.append(current)
                index++
            }
            builder.toString()
        }

        if (value.isNotBlank()) {
            tokens.add(UrlFilterToken(value = value, isExcluded = isExcluded))
        }
    }

    return tokens
}

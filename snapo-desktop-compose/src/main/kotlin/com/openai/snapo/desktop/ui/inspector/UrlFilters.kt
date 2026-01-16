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
        if (token.value.isNotBlank()) {
            if (token.isExcluded) {
                excludes.add(token.value)
            } else {
                includes.add(token.value)
            }
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
    val cursor = UrlSearchCursor(searchText)
    while (true) {
        val token = cursor.nextToken() ?: break
        tokens.add(token)
    }

    return tokens
}

private class UrlSearchCursor(
    private val text: String,
) {
    private val length = text.length
    private var index = 0

    fun nextToken(): UrlFilterToken? {
        skipWhitespace()
        if (index >= length) return null

        val isExcluded = consumeExcludePrefix()
        if (index >= length) return null

        val value = if (peek() == '"') {
            readQuotedToken()
        } else {
            readBareToken()
        }

        return UrlFilterToken(value = value, isExcluded = isExcluded)
    }

    private fun skipWhitespace() {
        while (index < length && text[index].isWhitespace()) {
            index++
        }
    }

    private fun consumeExcludePrefix(): Boolean {
        return if (peek() == '-') {
            index++
            true
        } else {
            false
        }
    }

    private fun readQuotedToken(): String {
        index++
        val builder = StringBuilder()
        while (index < length) {
            val current = text[index]
            if (current == '"') {
                index++
                break
            }

            if (current == '\\') {
                val escaped = readQuotedEscape()
                if (escaped != null) {
                    builder.append(escaped)
                } else {
                    builder.append(current)
                    index++
                }
            } else {
                builder.append(current)
                index++
            }
        }
        return builder.toString()
    }

    private fun readBareToken(): String {
        val builder = StringBuilder()
        while (index < length && !text[index].isWhitespace()) {
            val current = text[index]
            if (current == '\\') {
                val escaped = readBareEscape()
                if (escaped != null) {
                    builder.append(escaped)
                } else {
                    builder.append(current)
                    index++
                }
            } else {
                builder.append(current)
                index++
            }
        }
        return builder.toString()
    }

    private fun readQuotedEscape(): Char? {
        if (index + 1 >= length) return null
        val next = text[index + 1]
        return if (next == '"' || next == '\\') {
            index += 2
            next
        } else {
            null
        }
    }

    private fun readBareEscape(): Char? {
        if (index + 1 >= length) return null
        val next = text[index + 1]
        return if (next == '"' || next == '\\' || next.isWhitespace()) {
            index += 2
            next
        } else {
            null
        }
    }

    private fun peek(): Char? {
        return if (index < length) text[index] else null
    }
}

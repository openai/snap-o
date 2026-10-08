package com.openai.snapo.network

import java.util.Locale

// Match normalized text, but return offsets into the original body.
internal class TextMatcher(private val text: String) {
    private val lower = text.lowercase(Locale.ROOT)
    private val offsets: IntArray? by lazy {
        if (lower.length == text.length) {
            null
        } else {
            IntArray(lower.length).also { result ->
                var source = 0
                var target = 0
                while (source < text.length) {
                    val character = String(Character.toChars(text.codePointAt(source)))
                    val width = character.lowercase(Locale.ROOT).length
                    repeat(width) { result[target + it] = source + if (width == character.length) it else 0 }
                    source += character.length
                    target += width
                }
            }
        }
    }

    fun find(term: String): Int {
        val index = lower.indexOf(term.lowercase(Locale.ROOT))
        return if (index < 0) -1 else offsets?.get(index) ?: index
    }
}

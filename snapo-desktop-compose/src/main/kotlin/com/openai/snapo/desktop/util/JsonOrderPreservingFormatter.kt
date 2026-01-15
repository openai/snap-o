package com.openai.snapo.desktop.util

import kotlin.math.max

internal object JsonOrderPreservingFormatter {
    private const val IndentUnit = "  "

    fun format(text: String): String {
        val state = FormatterState(StringBuilder(text.length + 64))
        for (ch in text) {
            state.processChar(ch)
        }
        return state.output().trim()
    }

    private class FormatterState(
        private val out: StringBuilder,
    ) {
        private var indentLevel = 0
        private var insideString = false
        private var escaping = false

        fun output(): String = out.toString()

        fun processChar(ch: Char) {
            if (escaping) {
                appendChar(ch)
                escaping = false
                return
            }

            when (ch) {
                '\\' -> handleBackslash()
                '"' -> handleQuote()
                '{', '[' -> handleOpenBracket(ch)
                '}', ']' -> handleCloseBracket(ch)
                ',' -> handleComma()
                ':' -> handleColon()
                ' ', '\n', '\r', '\t' -> handleWhitespace(ch)
                else -> appendChar(ch)
            }
        }

        private fun appendChar(ch: Char) {
            out.append(ch)
        }

        private fun handleBackslash() {
            out.append('\\')
            if (insideString) escaping = true
        }

        private fun handleQuote() {
            out.append('"')
            insideString = !insideString
        }

        private fun handleOpenBracket(ch: Char) {
            out.append(ch)
            if (!insideString) {
                out.append('\n')
                indentLevel += 1
                appendIndent()
            }
        }

        private fun handleCloseBracket(ch: Char) {
            if (insideString) {
                out.append(ch)
                return
            }

            trimTrailingWhitespace()
            out.append('\n')
            indentLevel = max(indentLevel - 1, 0)
            appendIndent()
            out.append(ch)
        }

        private fun handleComma() {
            out.append(',')
            if (!insideString) {
                trimTrailingWhitespace()
                out.append('\n')
                appendIndent()
            }
        }

        private fun handleColon() {
            if (insideString) {
                out.append(':')
            } else {
                out.append(": ")
            }
        }

        private fun handleWhitespace(ch: Char) {
            if (insideString) out.append(ch)
        }

        private fun appendIndent() {
            repeat(indentLevel) { out.append(IndentUnit) }
        }

        private fun trimTrailingWhitespace() {
            while (out.isNotEmpty()) {
                val last = out.last()
                if (last == ' ' || last == '\t') {
                    out.setLength(out.length - 1)
                } else {
                    break
                }
            }
            if (out.isNotEmpty() && out.last() == '\n') {
                out.setLength(out.length - 1)
            }
        }
    }
}

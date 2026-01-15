package com.openai.snapo.desktop.inspector

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import com.openai.snapo.desktop.ui.theme.SnapOAccents

object NetworkInspectorStatusPresentation {
    @Composable
    fun color(code: Int): Color {
        val accents = SnapOAccents.current()
        return when (code) {
            in 200..299 -> accents.success
            in 400..599 -> accents.error
            in 300..399 -> accents.warning
            in 100..199 -> accents.info
            else -> accents.info
        }
    }

    fun displayName(code: Int): String {
        val override = overrides[code]
        if (override != null) return "$code $override"
        return "$code Done"
    }

    private val overrides: Map<Int, String> = mapOf(
        200 to "OK",
        201 to "Created",
        202 to "Accepted",
        204 to "No Content",
        301 to "Moved Permanently",
        302 to "Found",
        304 to "Not Modified",
        307 to "Temporary Redirect",
        308 to "Permanent Redirect",
        400 to "Bad Request",
        401 to "Unauthorized",
        403 to "Forbidden",
        404 to "Not Found",
        405 to "Method Not Allowed",
        409 to "Conflict",
        410 to "Gone",
        422 to "Unprocessable Entity",
        429 to "Too Many Requests",
        500 to "Internal Server Error",
        501 to "Not Implemented",
        502 to "Bad Gateway",
        503 to "Service Unavailable",
        504 to "Gateway Timeout",
    )
}

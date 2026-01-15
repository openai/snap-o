package com.openai.snapo.desktop.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance

internal object SnapOAccents {
    internal data class Palette(
        val success: Color,
        val error: Color,
        val warning: Color,
        val warningSurface: Color,
        val warningSurfaceStrong: Color,
        val onWarningSurfaceStrong: Color,
        val info: Color,
        val accentBlue: Color,
        val sidebarSelection: Color,
        val jsonKey: Color,
        val jsonNumber: Color,
        val jsonString: Color,
        val jsonNull: Color,
    )

    private val Light = Palette(
        success = Color(0xFF23A84A),
        error = Color(0xFFD04A3C),
        warning = Color(0xFFFF9B0D),
        warningSurface = Color(0xFFF7EBDD),
        warningSurfaceStrong = Color(0xFFF69E00),
        onWarningSurfaceStrong = Color(0xFFFFFFFF),
        info = Color(0xFF6F6F6F),
        accentBlue = Color(0xFF2778DB),
        sidebarSelection = Color(0xFFBCD6FF),
        jsonKey = Color(0xFF6E3A9C),
        jsonNumber = Color(0xFF2F6FAE),
        jsonString = Color(0xFFB74840),
        jsonNull = Color(0xFF8C7A72),
    )

    private val Dark = Palette(
        success = Color(0xFF5BCF8B),
        error = Color(0xFFFF7B6D),
        warning = Color(0xFFF2B15A),
        warningSurface = Color(0xFF3A2A18),
        warningSurfaceStrong = Color(0xFFB86A00),
        onWarningSurfaceStrong = Color.White,
        info = Color(0xFFB0B0B0),
        accentBlue = Color(0xFF5AA4E8),
        sidebarSelection = Color(0xFF2F4A72),
        jsonKey = Color(0xFFC38BE8),
        jsonNumber = Color(0xFF89B7F2),
        jsonString = Color(0xFFFF8F7D),
        jsonNull = Color(0xFFB9A596),
    )

    @Composable
    fun current(): Palette {
        val isDark = MaterialTheme.colorScheme.background.luminance() < 0.5f
        return if (isDark) Dark else Light
    }
}

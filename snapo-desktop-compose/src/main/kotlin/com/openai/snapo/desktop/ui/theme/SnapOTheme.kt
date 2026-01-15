package com.openai.snapo.desktop.ui.theme

import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.jetbrains.skiko.SystemTheme
import org.jetbrains.skiko.currentSystemTheme

private val LightColors = lightColorScheme(
    primary = Color(0xFF111111),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFE6E6E6),
    onPrimaryContainer = Color(0xFF111111),

    secondary = Color(0xFF2A2A2A),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFECECEC),
    onSecondaryContainer = Color(0xFF1B1B1B),

    background = Color(0xFFF7F7F7),
    onBackground = Color(0xFF111111),

    surface = Color(0xFFFDFDFD),
    onSurface = Color(0xFF151515),
    surfaceVariant = Color(0xFFF1F1F1),
    onSurfaceVariant = Color(0xFF6B6B6B),
    surfaceTint = Color(0xFF111111),
    surfaceBright = Color(0xFFFFFFFF),
    surfaceDim = Color(0xFFEAEAEA),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF6F6F6),
    surfaceContainer = Color(0xFFF0F0F0),
    surfaceContainerHigh = Color(0xFFE8E8E8),
    surfaceContainerHighest = Color(0xFFE1E1E1),

    outline = Color(0xFFD0D0D0),
    outlineVariant = Color(0xFFE3E3E3),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFECECEC),
    onPrimary = Color(0xFF101010),
    primaryContainer = Color(0xFF1B1B1B),
    onPrimaryContainer = Color(0xFFECECEC),

    secondary = Color(0xFFE0E0E0),
    onSecondary = Color(0xFF111111),
    secondaryContainer = Color(0xFF262626),
    onSecondaryContainer = Color(0xFFE0E0E0),

    background = Color(0xFF0F0F0F),
    onBackground = Color(0xFFF1F1F1),

    surface = Color(0xFF111111),
    onSurface = Color(0xFFF1F1F1),
    surfaceVariant = Color(0xFF1C1C1C),
    onSurfaceVariant = Color(0xFFB5B5B5),
    surfaceTint = Color(0xFFECECEC),
    surfaceBright = Color(0xFF1A1A1A),
    surfaceDim = Color(0xFF0B0B0B),
    surfaceContainerLowest = Color(0xFF0F0F0F),
    surfaceContainerLow = Color(0xFF141414),
    surfaceContainer = Color(0xFF191919),
    surfaceContainerHigh = Color(0xFF212121),
    surfaceContainerHighest = Color(0xFF2A2A2A),

    outline = Color(0xFF3A3A3A),
    outlineVariant = Color(0xFF242424),
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SnapOTheme(
    useDarkTheme: Boolean? = null,
    content: @Composable () -> Unit,
) {
    val resolvedDarkTheme = useDarkTheme ?: rememberSystemDarkTheme()
    MaterialExpressiveTheme(
        colorScheme = if (resolvedDarkTheme) DarkColors else LightColors,
        typography = SnapOTypography,
        shapes = SnapOShapes,
    ) {
        // Compose Material components assume touch; on desktop we can keep controls compact.
        CompositionLocalProvider(LocalMinimumInteractiveComponentSize provides 8.dp) {
            content()
        }
    }
}

@Composable
private fun rememberSystemDarkTheme(pollIntervalMs: Long = 1000L): Boolean {
    var isDark by remember { mutableStateOf(systemThemeIsDark() ?: false) }
    LaunchedEffect(Unit) {
        while (true) {
            val next = systemThemeIsDark()
            if (next != null && next != isDark) isDark = next
            delay(pollIntervalMs)
        }
    }
    return isDark
}

private fun systemThemeIsDark(): Boolean? {
    return when (currentSystemTheme) {
        SystemTheme.DARK -> true
        SystemTheme.LIGHT -> false
        SystemTheme.UNKNOWN -> null
    }
}

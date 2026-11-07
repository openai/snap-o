package com.openai.snapo.tweaks.overlay

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle

@Immutable
internal data class TweakOverlayColors(
    val surface: Color,
    val foreground: Color,
    val secondary: Color,
    val outline: Color,
    val field: Color,
    val curve: Color,
    val secondHandle: Color,
) {
    companion object {
        val Light = TweakOverlayColors(
            surface = Color(0xFFFFFFFF),
            foreground = Color(0xFF18212F),
            secondary = Color(0xFF68707D),
            outline = Color(0xFFE2E4E8),
            field = Color(0xFFF5F6F8),
            curve = Color(0xFF5468FF),
            secondHandle = Color(0xFFAA5B00),
        )
        val Dark = TweakOverlayColors(
            surface = Color(0xFF20242C),
            foreground = Color(0xFFF1F3F7),
            secondary = Color(0xFFADB5C2),
            outline = Color(0xFF434B59),
            field = Color(0xFF292F39),
            curve = Color(0xFF9AA8FF),
            secondHandle = Color(0xFFFFBC70),
        )
        val current: TweakOverlayColors
            @Composable get() = if (isSystemInDarkTheme()) Dark else Light
    }
}

internal fun tweakOverlayColorScheme(darkTheme: Boolean): ColorScheme {
    val colors = if (darkTheme) TweakOverlayColors.Dark else TweakOverlayColors.Light
    val base = if (darkTheme) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = colors.foreground,
        onPrimary = colors.surface,
        primaryContainer = colors.field,
        onPrimaryContainer = colors.foreground,
        secondary = colors.curve,
        tertiary = colors.secondHandle,
        background = colors.surface,
        onBackground = colors.foreground,
        surface = colors.surface,
        onSurface = colors.foreground,
        surfaceVariant = colors.field,
        onSurfaceVariant = colors.secondary,
        surfaceTint = Color.Transparent,
        inverseSurface = colors.foreground,
        inverseOnSurface = colors.surface,
        outline = colors.secondary,
        outlineVariant = colors.outline,
        surfaceContainerLowest = colors.surface,
        surfaceContainerLow = colors.field,
        surfaceContainer = colors.field,
        surfaceContainerHigh = colors.field,
        surfaceContainerHighest = colors.field,
    )
}

private val LightOverlayScheme = tweakOverlayColorScheme(darkTheme = false)
private val DarkOverlayScheme = tweakOverlayColorScheme(darkTheme = true)
private val OverlayTypography = Typography()
private val OverlayShapes = Shapes()

@Composable
internal fun TweakOverlayTheme(content: @Composable () -> Unit) {
    // Host apps may use colors that have no contrast against the overlay's surfaces.
    // MaterialTheme merges text styles, so clear any explicit host text color first.
    CompositionLocalProvider(LocalTextStyle provides TextStyle.Default) {
        MaterialTheme(
            colorScheme = if (isSystemInDarkTheme()) DarkOverlayScheme else LightOverlayScheme,
            typography = OverlayTypography,
            shapes = OverlayShapes,
            content = content,
        )
    }
}

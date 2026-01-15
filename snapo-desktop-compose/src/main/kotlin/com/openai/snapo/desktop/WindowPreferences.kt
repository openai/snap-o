package com.openai.snapo.desktop

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isSpecified
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.WindowState
import androidx.compose.ui.window.rememberWindowState
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import java.util.prefs.Preferences

private const val WindowPrefNode = "com.openai.snapo.desktop.window"
private const val PrefWidth = "windowWidthDp"
private const val PrefHeight = "windowHeightDp"
private const val PrefX = "windowX"
private const val PrefY = "windowY"
private const val PrefPlacement = "windowPlacement"
private const val WindowSaveDebounceMs = 250L

private data class WindowPreferences(
    val size: DpSize,
    val position: WindowPosition,
    val placement: WindowPlacement,
)

@Composable
internal fun rememberPersistedWindowState(): WindowState {
    val prefs = remember { Preferences.userRoot().node(WindowPrefNode) }
    val storedPreferences = remember { loadWindowPreferences(prefs) }
    val windowState = rememberWindowState(
        placement = storedPreferences.placement,
        position = storedPreferences.position,
        size = storedPreferences.size,
    )
    PersistWindowStateEffect(windowState = windowState, prefs = prefs)
    return windowState
}

@Composable
private fun PersistWindowStateEffect(windowState: WindowState, prefs: Preferences) {
    LaunchedEffect(windowState, prefs) {
        snapshotFlow {
            WindowPreferences(
                size = windowState.size,
                position = windowState.position,
                placement = windowState.placement,
            )
        }
            .distinctUntilChanged()
            .debounce(WindowSaveDebounceMs)
            .collect { preferences ->
                persistWindowPreferences(prefs, preferences)
            }
    }
}

private fun loadWindowPreferences(prefs: Preferences): WindowPreferences {
    val defaultSize = DpSize(800.dp, 600.dp)
    val defaultPosition = WindowPosition.PlatformDefault
    val defaultPlacement = WindowPlacement.Floating
    val width = prefs.getDouble(PrefWidth, Double.NaN)
    val height = prefs.getDouble(PrefHeight, Double.NaN)
    val size = if (isValidDimension(width) && isValidDimension(height)) {
        DpSize(width.dp, height.dp)
    } else {
        defaultSize
    }
    val x = prefs.getDouble(PrefX, Double.NaN)
    val y = prefs.getDouble(PrefY, Double.NaN)
    val position = if (x.isFinite() && y.isFinite()) {
        WindowPosition(x.dp, y.dp)
    } else {
        defaultPosition
    }
    val placementName = prefs.get(PrefPlacement, defaultPlacement.name)
    val placement = runCatching { WindowPlacement.valueOf(placementName) }
        .getOrDefault(defaultPlacement)
    return WindowPreferences(size = size, position = position, placement = placement)
}

private fun persistWindowPreferences(prefs: Preferences, preferences: WindowPreferences) {
    val size = preferences.size
    if (size.width.isSpecified && size.height.isSpecified) {
        prefs.putDouble(PrefWidth, size.width.value.toDouble())
        prefs.putDouble(PrefHeight, size.height.value.toDouble())
    } else {
        prefs.remove(PrefWidth)
        prefs.remove(PrefHeight)
    }
    val position = preferences.position
    if (position.isSpecified && position.x.isSpecified && position.y.isSpecified) {
        prefs.putDouble(PrefX, position.x.value.toDouble())
        prefs.putDouble(PrefY, position.y.value.toDouble())
    } else {
        prefs.remove(PrefX)
        prefs.remove(PrefY)
    }
    prefs.put(PrefPlacement, preferences.placement.name)
}

private fun isValidDimension(value: Double): Boolean {
    return value.isFinite() && value > 0
}

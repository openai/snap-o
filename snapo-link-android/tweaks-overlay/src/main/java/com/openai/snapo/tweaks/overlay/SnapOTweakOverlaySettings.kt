package com.openai.snapo.tweaks.overlay

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.edit

/** Controls whether the on-device tweak overlay is allowed to appear. */
object SnapOTweakOverlaySettings {

    private const val PreferencesName = "com.openai.snapo.tweaks.overlay"
    private const val EnabledPreference = "enabled"
    private const val HorizontalPositionPreference = "horizontal_position"
    private const val VerticalPositionPreference = "vertical_position"
    private const val DefaultHorizontalPosition = 1f
    private const val DefaultVerticalPosition = 0.48f

    private var enabledOverride by mutableStateOf<Boolean?>(null)
    private val horizontalPositionState = mutableFloatStateOf(DefaultHorizontalPosition)
    private val verticalPositionState = mutableFloatStateOf(DefaultVerticalPosition)
    private var pendingEnabled: Boolean? = null
    private var pendingHorizontalPosition: Float? = null
    private var pendingVerticalPosition: Float? = null
    private var preferences by mutableStateOf<SharedPreferences?>(null)

    internal val horizontalPosition: Float by horizontalPositionState

    internal val verticalPosition: Float by verticalPositionState

    /** Whether the floating tweak overlay is enabled for this application. */
    var isEnabled: Boolean
        get() = resolveOverlayEnabled(enabledOverride) {
            preferences?.getBoolean(EnabledPreference, false) ?: false
        }
        set(value) {
            enabledOverride = value

            val currentPreferences = preferences
            if (currentPreferences == null) {
                pendingEnabled = value
            } else {
                currentPreferences.edit { putBoolean(EnabledPreference, value) }
            }
        }

    internal fun updateHorizontalPosition(position: Float) {
        val normalizedPosition = normalizeOverlayPosition(position, DefaultHorizontalPosition)
        horizontalPositionState.floatValue = normalizedPosition

        if (preferences == null) {
            pendingHorizontalPosition = normalizedPosition
        }
    }

    internal fun offsetVerticalPosition(delta: Float) {
        val position = verticalPositionState.floatValue + delta
        val normalizedPosition = normalizeOverlayPosition(position, DefaultVerticalPosition)
        verticalPositionState.floatValue = normalizedPosition

        if (preferences == null) {
            pendingVerticalPosition = normalizedPosition
        }
    }

    internal fun persistPositions() {
        val currentPreferences = preferences ?: return

        currentPreferences.edit {
            putFloat(HorizontalPositionPreference, horizontalPositionState.floatValue)
            putFloat(VerticalPositionPreference, verticalPositionState.floatValue)
        }
    }

    internal fun initialize(context: Context) {
        if (preferences != null) {
            return
        }

        val applicationPreferences = context.applicationContext.getSharedPreferences(
            PreferencesName,
            Context.MODE_PRIVATE,
        )
        horizontalPositionState.floatValue = resolveOverlayPosition(
            pendingPosition = pendingHorizontalPosition,
            defaultPosition = DefaultHorizontalPosition,
        ) {
            applicationPreferences.getFloat(
                HorizontalPositionPreference,
                DefaultHorizontalPosition,
            )
        }
        verticalPositionState.floatValue = resolveOverlayPosition(
            pendingPosition = pendingVerticalPosition,
            defaultPosition = DefaultVerticalPosition,
        ) {
            applicationPreferences.getFloat(
                VerticalPositionPreference,
                DefaultVerticalPosition,
            )
        }
        preferences = applicationPreferences

        pendingEnabled?.let { value ->
            applicationPreferences.edit { putBoolean(EnabledPreference, value) }
            pendingEnabled = null
        }

        if (pendingHorizontalPosition != null || pendingVerticalPosition != null) {
            applicationPreferences.edit {
                pendingHorizontalPosition?.let { putFloat(HorizontalPositionPreference, it) }
                pendingVerticalPosition?.let { putFloat(VerticalPositionPreference, it) }
            }
            pendingHorizontalPosition = null
            pendingVerticalPosition = null
        }
    }
}

internal inline fun resolveOverlayEnabled(
    pendingEnabled: Boolean?,
    storedEnabled: () -> Boolean,
): Boolean = pendingEnabled ?: storedEnabled()

internal inline fun resolveOverlayPosition(
    pendingPosition: Float?,
    defaultPosition: Float,
    storedPosition: () -> Float,
): Float = normalizeOverlayPosition(pendingPosition ?: storedPosition(), defaultPosition)

internal fun normalizeOverlayPosition(
    position: Float,
    defaultPosition: Float,
): Float = if (position.isFinite()) {
    position.coerceIn(0f, 1f)
} else {
    defaultPosition
}

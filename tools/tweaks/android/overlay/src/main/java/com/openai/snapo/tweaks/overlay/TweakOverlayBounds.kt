package com.openai.snapo.tweaks.overlay

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.IntSize

@Stable
internal class TweakOverlayBounds {

    var containerSize by mutableStateOf(IntSize.Zero)
    var buttonSize by mutableStateOf(IntSize.Zero)
    var panelSize by mutableStateOf(IntSize.Zero)

    val horizontalTravel: Int
        get() = (containerSize.width - buttonSize.width).coerceAtLeast(0)

    fun verticalTravel(isExpanded: Boolean): Int {
        val overlayHeight = if (isExpanded) panelSize.height else buttonSize.height
        return (containerSize.height - overlayHeight).coerceAtLeast(0)
    }
}

package com.openai.snapo.desktop.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp

internal object SnapOMenuDefaults {
    val shape
        @Composable
        get() = MaterialTheme.shapes.small

    val containerColor
        @Composable
        get() = MaterialTheme.colorScheme.background

    val border
        @Composable
        get() = BorderStroke(1.dp, MaterialTheme.colorScheme.outline)
}

package com.openai.snapo.tweaks.overlay

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/** Does not render an in-app tweak inspector in release builds. */
@Composable
fun SnapOTweakOverlay(
    @Suppress("UNUSED_PARAMETER")
    modifier: Modifier = Modifier,
) = Unit

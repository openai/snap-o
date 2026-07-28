@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.Color

/** Returns observable release-build state for the current floating-point default. */
@Composable
fun tweakFloat(
    name: String,
    default: Float,
    min: Float? = null,
    max: Float? = null,
    step: Float? = null,
): State<Float> = rememberUpdatedState(default)

/** Returns observable release-build state for the current integer default. */
@Composable
fun tweakInt(
    name: String,
    default: Int,
    min: Int? = null,
    max: Int? = null,
    step: Int? = null,
): State<Int> = rememberUpdatedState(default)

/** Returns observable release-build state for the current color default. */
@Composable
fun tweakColor(
    name: String,
    default: Color,
): State<Color> = rememberUpdatedState(default)

/** Returns observable release-build state for the current boolean default. */
@Composable
fun tweakBoolean(
    name: String,
    default: Boolean,
): State<Boolean> = rememberUpdatedState(default)

/** Returns observable release-build state for the current text default. */
@Composable
fun tweakString(
    name: String,
    default: String,
): State<String> = rememberUpdatedState(default)

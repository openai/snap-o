@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.Color

/** Returns observable release-build state for the current floating-point default. */
@Composable
fun tweak(
    default: Float,
    name: String,
    range: ClosedFloatingPointRange<Float>? = null,
    step: Float? = null,
): State<Float> = rememberUpdatedState(default)

/** Returns observable release-build state for the current integer default. */
@Composable
fun tweak(
    default: Int,
    name: String,
    range: IntRange? = null,
    step: Int? = null,
): State<Int> = rememberUpdatedState(default)

/** Returns observable release-build state for the current color default. */
@Composable
fun tweak(
    default: Color,
    name: String,
): State<Color> = rememberUpdatedState(default)

/** Returns observable release-build state for the current boolean default. */
@Composable
fun tweak(
    default: Boolean,
    name: String,
): State<Boolean> = rememberUpdatedState(default)

/** Returns observable release-build state for the current text default. */
@Composable
fun tweak(
    default: String,
    name: String,
): State<String> = rememberUpdatedState(default)

/** Returns observable release-build state for the current enum default. */
@Composable
fun <E : Enum<E>> tweak(
    default: E,
    name: String,
): State<E> = rememberUpdatedState(default)

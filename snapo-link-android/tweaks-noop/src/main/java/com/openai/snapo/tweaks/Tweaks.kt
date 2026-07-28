@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Returns the release-build floating-point value unchanged. */
@Composable
fun tweakFloat(
    name: String,
    default: Float,
    min: Float? = null,
    max: Float? = null,
    step: Float? = null,
): Float = default

/** Returns the release-build integer value unchanged. */
@Composable
fun tweakInt(
    name: String,
    default: Int,
    min: Int? = null,
    max: Int? = null,
    step: Int? = null,
): Int = default

/** Returns the release-build color unchanged. */
@Composable
fun tweakColor(
    name: String,
    default: Color,
): Color = default

/** Returns the release-build boolean value unchanged. */
@Composable
fun tweakBoolean(
    name: String,
    default: Boolean,
): Boolean = default

/** Returns the release-build text unchanged. */
@Composable
fun tweakString(
    name: String,
    default: String,
): String = default

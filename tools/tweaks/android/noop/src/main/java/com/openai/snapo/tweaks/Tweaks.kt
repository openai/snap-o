@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.tweaks

import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.graphics.Color

/**
 * Reads and writes the current application-owned source without registering a tool.
 * Make source-backed state writes on the main thread.
 *
 * In live builds, sources with the same name must use the same setting and value type.
 * The first active source handles values, updates, resets, status, and observation.
 * When it leaves, the next active source takes over.
 * Conflicts are not checked and can cause wrong values or runtime errors.
 */
@Composable
fun <T : Any> tweak(
    source: TweakSource<T>,
    name: String,
): MutableState<T> {
    val latestSource = rememberUpdatedState(source)
    return remember {
        object : MutableState<T> {
            override var value: T
                get() = latestSource.value.value
                set(value) { latestSource.value.value = value }

            override fun component1(): T = value
            override fun component2(): (T) -> Unit = { value = it }
        }
    }
}

/** Returns local mutable curve state without registering a tool. */
@Composable
fun tweak(
    default: BezierCurve,
    name: String,
): MutableState<BezierCurve> = remember(name, default) { mutableStateOf(default) }

/** Returns local mutable state initialized from the floating-point default. */
@Composable
fun tweak(
    default: Float,
    name: String,
    range: ClosedFloatingPointRange<Float>? = null,
    step: Float? = null,
): MutableState<Float> = remember(name, default, range, step) { mutableStateOf(default) }

/** Returns local mutable state initialized from the integer default. */
@Composable
fun tweak(
    default: Int,
    name: String,
    range: IntRange? = null,
    step: Int? = null,
): MutableState<Int> = remember(name, default, range, step) { mutableStateOf(default) }

/** Returns local mutable state initialized from the color default. */
@Composable
fun tweak(
    default: Color,
    name: String,
): MutableState<Color> = remember(name, default) { mutableStateOf(default) }

/** Returns local mutable state initialized from the boolean default. */
@Composable
fun tweak(
    default: Boolean,
    name: String,
): MutableState<Boolean> = remember(name, default) { mutableStateOf(default) }

/** Returns local mutable state initialized from the text default. */
@Composable
fun tweak(
    default: String,
    name: String,
): MutableState<String> = remember(name, default) { mutableStateOf(default) }

/** Returns local mutable state initialized from the enum default. */
@Composable
fun <E : Enum<E>> tweak(
    default: E,
    name: String,
): MutableState<E> = remember(name, default) { mutableStateOf(default) }

/** Returns Unit without exposing or invoking the supplied action in no-op builds. */
@Composable
fun TweakAction(
    name: String,
    onInvoke: () -> Unit,
) = Unit

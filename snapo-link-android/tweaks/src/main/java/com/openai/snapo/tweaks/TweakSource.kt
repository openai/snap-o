package com.openai.snapo.tweaks

import kotlinx.coroutines.flow.Flow

/**
 * An application-owned tweak whose changes can be observed while it is active.
 *
 * Snap-O reads and writes [value], reads [isModified], calls [reset], and collects [observe]
 * on the Android main thread.
 */
interface TweakSource<T : Any> {
    /** The current application-owned value, read only when its value is needed. */
    var value: T

    /** Whether this source currently has an application-owned override. */
    val isModified: Boolean

    /** Removes this source's override without changing unrelated values. */
    fun reset()

    /** Emits whenever [value] or [isModified] may have changed while this source is selected. */
    fun observe(): Flow<Unit>
}

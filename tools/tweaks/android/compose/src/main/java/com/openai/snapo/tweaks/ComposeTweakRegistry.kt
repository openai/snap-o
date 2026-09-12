package com.openai.snapo.tweaks

import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.structuralEqualityPolicy
import com.openai.snapo.tweaks.internal.TweakRegistry

/** Bridges registry invalidation into snapshots without putting Compose in the core. */
internal object ComposeTweakRegistry {
    private val revision = mutableLongStateOf(0)

    init {
        TweakRegistry.observeChanges { invalidate() }
    }

    @Synchronized
    private fun invalidate() {
        Snapshot.withMutableSnapshot { revision.longValue += 1 }
    }

    fun readRevision() {
        revision.longValue
    }

    fun <T> state(read: () -> T): State<T> = derivedStateOf(structuralEqualityPolicy()) {
        readRevision()
        read()
    }
}

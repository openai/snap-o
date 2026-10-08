package com.openai.snapo.demo.tweaks

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.snapshotFlow
import com.openai.snapo.tweaks.TweakSource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

internal enum class MotionState { A, B }

internal class MotionStateSource(private val state: MutableState<MotionState>) : TweakSource<MotionState> {
    override var value: MotionState
        get() = state.value
        set(value) { state.value = value }

    override val isModified: Boolean
        get() = value != MotionState.A

    override fun reset() {
        value = MotionState.A
    }

    override fun observe(): Flow<Unit> = snapshotFlow { state.value }.map { Unit }

    fun toggle() {
        value = if (value == MotionState.A) MotionState.B else MotionState.A
    }
}

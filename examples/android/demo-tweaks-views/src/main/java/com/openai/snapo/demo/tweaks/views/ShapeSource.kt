package com.openai.snapo.demo.tweaks.views

import com.openai.snapo.tweaks.TweakSource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map

enum class ShapeKind { Circle, Square }

internal class ShapeSource : TweakSource<ShapeKind> {
    private val state = MutableStateFlow(ShapeKind.Circle)

    override var value: ShapeKind
        get() = state.value
        set(value) { state.value = value }

    override val isModified: Boolean
        get() = value != ShapeKind.Circle

    override fun reset() {
        value = ShapeKind.Circle
    }

    override fun observe(): Flow<Unit> = state.map { Unit }

    fun toggle() {
        value = if (value == ShapeKind.Circle) ShapeKind.Square else ShapeKind.Circle
    }
}

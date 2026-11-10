package com.openai.snapo.tweaks.overlay

import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.saveable.rememberSaveable
import com.openai.snapo.tweaks.SnapOTweakEntry

internal class TweakOverlayScrollPosition {
    private var firstVisibleIndex = 0
    private var firstVisibleScrollOffset = 0
    private var visibleOffsets = emptyList<Pair<String, Int>>()

    @Composable
    fun rememberListState(tweaks: List<SnapOTweakEntry>): LazyListState {
        val state = rememberSaveable(this, saver = LazyListState.Saver) { restore(tweaks) }
        DisposableEffect(this, state) {
            onDispose { record(state) }
        }
        return state
    }

    private fun record(state: LazyListState) {
        val visibleItems = state.layoutInfo.visibleItemsInfo
        if (visibleItems.isEmpty()) return
        firstVisibleIndex = state.firstVisibleItemIndex
        firstVisibleScrollOffset = state.firstVisibleItemScrollOffset
        visibleOffsets = visibleItems.map { item -> item.key as String to item.offset }
    }

    private fun restore(tweaks: List<SnapOTweakEntry>): LazyListState {
        for ((name, offset) in visibleOffsets) {
            val index = tweaks.indexOfFirst { it.name == name }
            // Scrolling forward moves a row up, so negate its measured position.
            if (index >= 0) return LazyListState(index, -offset)
        }
        val index = firstVisibleIndex.coerceAtMost(tweaks.lastIndex.coerceAtLeast(0))
        return LazyListState(index, firstVisibleScrollOffset)
    }
}

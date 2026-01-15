package com.openai.snapo.desktop.ui

import androidx.compose.foundation.ContextMenuItem
import androidx.compose.foundation.ContextMenuRepresentation
import androidx.compose.foundation.ContextMenuState
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.round
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties

internal object SnapOContextMenuRepresentation : ContextMenuRepresentation {
    @Composable
    override fun Representation(state: ContextMenuState, items: () -> List<ContextMenuItem>) {
        val status = state.status
        if (status is ContextMenuState.Status.Open) {
            val anchorPosition = status.rect.center.round()
            val popupPositionProvider = remember(status) {
                SnapOContextMenuPositionProvider(anchorPosition)
            }
            Popup(
                popupPositionProvider = popupPositionProvider,
                onDismissRequest = { state.status = ContextMenuState.Status.Closed },
                properties = PopupProperties(focusable = true),
            ) {
                DisableSelection {
                    ContextMenuSurface(
                        items = items,
                        onItemClick = {
                            state.status = ContextMenuState.Status.Closed
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun ContextMenuSurface(
    items: () -> List<ContextMenuItem>,
    onItemClick: () -> Unit,
) {
    SnapOContextMenuSurface {
        items()
            .asSequence()
            .filter { it.label.isNotBlank() }
            .forEach { item ->
                SnapOContextMenuItem(
                    label = item.label,
                    onClick = {
                        onItemClick()
                        item.onClick()
                    },
                )
            }
    }
}

private class SnapOContextMenuPositionProvider(
    private val anchorPosition: IntOffset,
    private val onPositionCalculated: ((position: IntOffset, menuBounds: IntRect) -> Unit)? = null,
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val resultPosition =
            IntOffset(
                x = alignPopupAxis(
                    position = anchorBounds.left + anchorPosition.x,
                    popupLength = popupContentSize.width,
                    windowLength = windowSize.width,
                    closeAffinity = layoutDirection == LayoutDirection.Ltr,
                ),
                y = alignPopupAxis(
                    position = anchorBounds.top + anchorPosition.y,
                    popupLength = popupContentSize.height,
                    windowLength = windowSize.height,
                ),
            )
        onPositionCalculated?.invoke(anchorPosition, IntRect(resultPosition, popupContentSize))
        return resultPosition
    }
}

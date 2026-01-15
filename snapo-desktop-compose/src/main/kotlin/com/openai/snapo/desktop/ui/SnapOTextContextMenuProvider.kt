package com.openai.snapo.desktop.ui

import androidx.compose.foundation.LocalContextMenuRepresentation
import androidx.compose.foundation.MutatorMutex
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuComponent
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuSeparator
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuSession
import androidx.compose.foundation.text.contextmenu.provider.LocalTextContextMenuDropdownProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuDataProvider
import androidx.compose.foundation.text.contextmenu.provider.TextContextMenuProvider
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.neverEqualPolicy
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.round
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import kotlinx.coroutines.channels.Channel

@Composable
internal fun SnapOContextMenuProviders(
    content: @Composable () -> Unit,
) {
    var layoutCoordinates: LayoutCoordinates? by remember {
        mutableStateOf(null, neverEqualPolicy())
    }
    val textContextMenuProvider = remember { SnapOTextContextMenuProvider() }

    DisposableEffect(textContextMenuProvider) {
        onDispose { textContextMenuProvider.cancel() }
    }

    CompositionLocalProvider(
        LocalContextMenuRepresentation provides SnapOContextMenuRepresentation,
        LocalTextContextMenuDropdownProvider provides textContextMenuProvider,
    ) {
        Box(
            propagateMinConstraints = true,
            modifier = Modifier.onGloballyPositioned { layoutCoordinates = it },
        ) {
            content()
            textContextMenuProvider.ContextMenu { checkNotNull(layoutCoordinates) }
        }
    }
}

internal class SnapOTextContextMenuProvider : TextContextMenuProvider {
    private val mutatorMutex = MutatorMutex()
    private var session: SessionImpl? by mutableStateOf(null)

    override suspend fun showTextContextMenu(dataProvider: TextContextMenuDataProvider) {
        val localSession = SessionImpl(dataProvider)
        mutatorMutex.mutate {
            try {
                session = localSession
                localSession.awaitClose()
            } finally {
                session = null
            }
        }
    }

    @Composable
    fun ContextMenu(anchorLayoutCoordinates: () -> LayoutCoordinates) {
        val activeSession = session ?: return
        SnapOTextContextMenu(
            session = activeSession,
            dataProvider = activeSession.dataProvider,
            anchorLayoutCoordinates = anchorLayoutCoordinates,
        )
    }

    fun cancel() {
        session?.close()
    }

    private inner class SessionImpl(val dataProvider: TextContextMenuDataProvider) :
        TextContextMenuSession {
        private val channel = Channel<Unit>()

        override fun close() {
            channel.trySend(Unit)
        }

        suspend fun awaitClose() {
            channel.receive()
        }
    }
}

@Composable
private fun SnapOTextContextMenu(
    session: TextContextMenuSession,
    dataProvider: TextContextMenuDataProvider,
    anchorLayoutCoordinates: () -> LayoutCoordinates,
) {
    val popupPositionProvider =
        remember(dataProvider) {
            SnapOTextContextMenuPositionProvider {
                dataProvider.position(anchorLayoutCoordinates()).round()
            }
        }
    val data by remember(dataProvider) { derivedStateOf(dataProvider::data) }

    Popup(
        popupPositionProvider = popupPositionProvider,
        onDismissRequest = { session.close() },
        properties = PopupProperties(focusable = true),
    ) {
        DisableSelection {
            SnapOContextMenuSurface {
                data.components.forEach { component ->
                    when (component) {
                        TextContextMenuSeparator -> SnapOContextMenuSeparator()
                        else -> {
                            val item = component.asSnapOTextItem() ?: return@forEach
                            SnapOContextMenuItem(
                                label = item.label,
                                enabled = item.enabled,
                                onClick = {
                                    item.onClick(session)
                                    session.close()
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

private class SnapOTextContextMenuPositionProvider(
    private val anchorPositionProvider: () -> IntOffset,
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val anchorPosition = anchorPositionProvider()
        return IntOffset(
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
    }
}

private data class SnapOTextContextMenuItem(
    val label: String,
    val enabled: Boolean,
    val onClick: (TextContextMenuSession) -> Unit,
)

@Suppress("UNCHECKED_CAST")
private fun TextContextMenuComponent.asSnapOTextItem(): SnapOTextContextMenuItem? {
    val itemClass = textContextMenuItemClass ?: return null
    if (!itemClass.isInstance(this)) return null
    val label = itemClass.getMethod("getLabel").invoke(this) as String
    val enabled = itemClass.getMethod("getEnabled").invoke(this) as Boolean
    val onClick = itemClass.getMethod("getOnClick").invoke(this) as (TextContextMenuSession) -> Unit
    return SnapOTextContextMenuItem(label = label, enabled = enabled, onClick = onClick)
}

private val textContextMenuItemClass: Class<*>? =
    runCatching {
        Class.forName(
            "androidx.compose.foundation.text.contextmenu.data.TextContextMenuItemWithComposableLeadingIcon"
        )
    }.getOrNull()

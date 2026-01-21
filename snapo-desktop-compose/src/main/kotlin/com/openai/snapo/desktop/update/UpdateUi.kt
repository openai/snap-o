package com.openai.snapo.desktop.update

import androidx.compose.runtime.Composable
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyShortcut
import androidx.compose.ui.window.FrameWindowScope
import androidx.compose.ui.window.MenuBar

@Composable
internal fun FrameWindowScope.SnapOMenuBar(
    controller: UpdateController,
    onNewWindow: () -> Unit,
    onCheckForUpdates: () -> Unit,
    onCloseRequest: () -> Unit,
) {
    MenuBar {
        Menu("File") {
            Item(
                text = "New Window",
                shortcut = KeyShortcut(Key.N, meta = true),
                onClick = onNewWindow,
            )
            Item(
                text = "Close",
                shortcut = KeyShortcut(Key.W, meta = true),
                onClick = onCloseRequest,
            )
        }
        Menu("Tools") {
            Item(
                text = if (controller.isChecking) "Checking for Updates..." else "Check for Updates...",
                enabled = !controller.isChecking,
                onClick = onCheckForUpdates,
            )
        }
    }
}

package com.openai.snapo.desktop

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import com.openai.snapo.desktop.di.AppGraph
import com.openai.snapo.desktop.ui.SnapOContextMenuProviders
import com.openai.snapo.desktop.ui.inspector.NetworkInspectorScreen
import com.openai.snapo.desktop.ui.theme.SnapOTheme
import com.openai.snapo.desktop.update.AutoCheckDecision
import com.openai.snapo.desktop.update.SnapOMenuBar
import com.openai.snapo.desktop.update.UpdateCheckSource
import com.openai.snapo.desktop.update.UpdateChecker
import com.openai.snapo.desktop.update.UpdateController
import com.openai.snapo.desktop.update.autoCheckDecision
import dev.zacsweers.metro.createGraph
import kotlinx.coroutines.launch
import java.awt.Desktop
import java.net.URI
import java.util.UUID

fun main() {
    configurePlatformAppearance()
    application {
        val windows = remember { mutableStateListOf(createInspectorWindow()) }
        val updateController = remember {
            UpdateController(
                checker = UpdateChecker(),
                currentVersion = BuildInfo.VERSION,
                currentBuildNumber = BuildInfo.BUILD_NUMBER,
                onUpdateAvailable = { openSnapOUpdate() },
            )
        }
        val scope = rememberCoroutineScope()
        val decision = remember { autoCheckDecision() }
        LaunchedEffect(decision) {
            when (decision) {
                AutoCheckDecision.Enabled -> updateController.checkForUpdates(UpdateCheckSource.Auto)
                AutoCheckDecision.PromptHost -> openSnapOUpdate()
                AutoCheckDecision.Disabled -> Unit
            }
        }

        fun openNewWindow() {
            windows.add(createInspectorWindow())
        }

        fun closeWindow(window: InspectorWindow) {
            window.graph.store.stop()
            windows.remove(window)
            if (windows.isEmpty()) {
                exitApplication()
            }
        }

        windows.forEach { window ->
            key(window.id) {
                val windowState = rememberPersistedWindowState()
                Window(
                    onCloseRequest = { closeWindow(window) },
                    title = "Snap-O Network Inspector",
                    state = windowState,
                ) {
                    SnapOMenuBar(
                        controller = updateController,
                        onNewWindow = ::openNewWindow,
                        onCheckForUpdates = {
                            scope.launch {
                                updateController.checkForUpdates(UpdateCheckSource.Manual)
                            }
                        },
                        onCloseRequest = { closeWindow(window) },
                    )
                    App(window.graph)
                }
            }
        }
    }
}

private fun configurePlatformAppearance() {
    if (System.getProperty("os.name").startsWith("Mac")) {
        System.setProperty("apple.awt.application.appearance", "system")
    }
}

@Composable
private fun App(appGraph: AppGraph) {
    SnapOTheme {
        SnapOContextMenuProviders {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.background,
            ) {
                NetworkInspectorScreen(appGraph.store)
            }
        }
    }
}

private fun openSnapOUpdate() {
    runCatching {
        if (Desktop.isDesktopSupported()) {
            Desktop.getDesktop().browse(URI("snapo://check-updates"))
        }
    }
}

private data class InspectorWindow(
    val id: String = UUID.randomUUID().toString(),
    val graph: AppGraph,
)

private fun createInspectorWindow(): InspectorWindow {
    return InspectorWindow(graph = createGraph<AppGraph>())
}

@file:OptIn(
    ExperimentalComposeUiApi::class,
    ExperimentalSplitPaneApi::class,
)

package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerIcon
import androidx.compose.ui.input.pointer.pointerHoverIcon
import androidx.compose.ui.unit.dp
import com.openai.snapo.desktop.inspector.NetworkInspectorItemId
import com.openai.snapo.desktop.inspector.NetworkInspectorListItemUiModel
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestUiModel
import com.openai.snapo.desktop.inspector.NetworkInspectorServerUiModel
import com.openai.snapo.desktop.inspector.NetworkInspectorStore
import com.openai.snapo.desktop.inspector.NetworkInspectorWebSocketUiModel
import com.openai.snapo.desktop.inspector.SnapOLinkServerId
import com.openai.snapo.desktop.ui.theme.Spacings
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import org.jetbrains.compose.splitpane.ExperimentalSplitPaneApi
import org.jetbrains.compose.splitpane.HorizontalSplitPane
import org.jetbrains.compose.splitpane.SplitPaneState
import org.jetbrains.compose.splitpane.rememberSplitPaneState
import java.awt.Cursor
import java.awt.Desktop
import java.net.URI
import java.util.prefs.Preferences

@Composable
fun NetworkInspectorScreen(store: NetworkInspectorStore) {
    val screenState = rememberNetworkInspectorScreenState(store)
    NetworkInspectorScreenContent(
        store = store,
        sidebarState = screenState.sidebarState,
        sidebarActions = screenState.sidebarActions,
        detailState = screenState.detailState,
        uiStateStore = screenState.uiStateStore,
    )
}

private data class NetworkInspectorScreenState(
    val sidebarState: SidebarState,
    val sidebarActions: SidebarActions,
    val detailState: DetailPaneState,
    val uiStateStore: InspectorUiStateStore,
)

@Composable
private fun rememberNetworkInspectorScreenState(
    store: NetworkInspectorStore,
): NetworkInspectorScreenState {
    val servers by store.servers.collectAsState()
    val items by store.items.collectAsState()
    val sortOrder by store.listSortOrder.collectAsState()
    var selectedItemId by remember { mutableStateOf<NetworkInspectorItemId?>(null) }
    var searchText by remember { mutableStateOf("") }
    var selectedServerId by remember { mutableStateOf<SnapOLinkServerId?>(null) }
    var serverMenuExpanded by remember { mutableStateOf(false) }
    val (selectedServer, serverScopedItems, filteredItems) = rememberDerivedState(
        servers = servers,
        items = items,
        selectedServerId = selectedServerId,
        searchText = searchText,
    )
    SyncSelectedServerEffect(
        servers,
        selectedServerId,
        onSelectedServerIdChange = { selectedServerId = it },
    )
    SyncSelectedItemEffect(
        filteredItems,
        selectedItemId,
        onSelectedItemIdChange = { selectedItemId = it },
    )
    RetainServerEffect(store = store, selectedServerId = selectedServerId)
    ReplayFeatureEffect(store, selectedServerId, servers)
    val sidebarState = SidebarState(
        servers = servers,
        selectedServer = selectedServer,
        serverMenuExpanded = serverMenuExpanded,
        items = items,
        serverScopedItems = serverScopedItems,
        filteredItems = filteredItems,
        selectedItemId = selectedItemId,
        searchText = searchText,
        sortOrder = sortOrder,
    )
    val uiStateStore = remember { InspectorUiStateStore() }
    val sidebarActions = SidebarActions(
        onSelectedServerIdChange = { selectedServerId = it },
        onServerMenuExpandedChange = { serverMenuExpanded = it },
        onSelectedItemIdChange = { selectedItemId = it },
        onSearchTextChange = { searchText = it },
        onToggleSortOrder = { store.toggleSortOrder() },
        onClearComplete = { store.clearCompleted() },
    )
    val detailState = DetailPaneState(servers, selectedServer, serverScopedItems, selectedItemId)
    return NetworkInspectorScreenState(
        sidebarState,
        sidebarActions,
        detailState,
        uiStateStore,
    )
}

private data class InspectorDerivedState(
    val selectedServer: NetworkInspectorServerUiModel?,
    val serverScopedItems: List<NetworkInspectorListItemUiModel>,
    val filteredItems: List<NetworkInspectorListItemUiModel>,
)

@Composable
private fun rememberDerivedState(
    servers: List<NetworkInspectorServerUiModel>,
    items: List<NetworkInspectorListItemUiModel>,
    selectedServerId: SnapOLinkServerId?,
    searchText: String,
): InspectorDerivedState {
    val selectedServer = remember(servers, selectedServerId) {
        servers.firstOrNull { it.id == selectedServerId } ?: servers.firstOrNull()
    }
    val serverScopedItems = remember(items, selectedServerId) {
        items.filter { item ->
            selectedServerId == null || item.serverId == selectedServerId
        }
    }
    val filteredItems = remember(serverScopedItems, searchText) {
        if (searchText.isBlank()) {
            serverScopedItems
        } else {
            serverScopedItems.filter { it.url.contains(searchText, ignoreCase = true) }
        }
    }
    return InspectorDerivedState(
        selectedServer = selectedServer,
        serverScopedItems = serverScopedItems,
        filteredItems = filteredItems,
    )
}

private data class DetailPaneState(
    val servers: List<NetworkInspectorServerUiModel>,
    val selectedServer: NetworkInspectorServerUiModel?,
    val serverScopedItems: List<NetworkInspectorListItemUiModel>,
    val selectedItemId: NetworkInspectorItemId?,
)

private const val SplitPanePrefNode = "com.openai.snapo.desktop.networkInspector"
private const val SplitPanePositionKey = "sidebarSplitPosition"
private const val SplitPaneDefaultPosition = 0.28f
private const val SplitPaneSaveDebounceMs = 250L

@Composable
private fun NetworkInspectorScreenContent(
    store: NetworkInspectorStore,
    sidebarState: SidebarState,
    sidebarActions: SidebarActions,
    detailState: DetailPaneState,
    uiStateStore: InspectorUiStateStore,
) {
    val splitPaneState = rememberPersistedSplitPaneState()

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = Color.Transparent,
    ) {
        HorizontalSplitPane(
            splitPaneState = splitPaneState,
            modifier = Modifier.fillMaxSize(),
        ) {
            first(minSize = 260.dp) {
                Sidebar(
                    state = sidebarState,
                    actions = sidebarActions,
                    contextMenuItems = { item -> sidebarContextMenuItems(store, item) },
                    modifier = Modifier.fillMaxSize(),
                )
            }

            second(minSize = 360.dp) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.surfaceBright,
                ) {
                    DetailPane(
                        store = store,
                        state = detailState,
                        uiStateStore = uiStateStore,
                    )
                }
            }

            splitter {
                visiblePart {
                    VerticalDivider(modifier = Modifier.fillMaxHeight().width(1.dp))
                }
                handle {
                    Box(
                        modifier = Modifier
                            .markAsHandle()
                            .fillMaxHeight()
                            .width(Spacings.md)
                            .pointerHoverIcon(PointerIcon(Cursor(Cursor.E_RESIZE_CURSOR)))
                    )
                }
            }
        }
    }
}

@OptIn(FlowPreview::class)
@Composable
private fun rememberPersistedSplitPaneState(): SplitPaneState {
    val prefs = remember { Preferences.userRoot().node(SplitPanePrefNode) }
    val initialPosition = remember(prefs) {
        val stored = prefs.getDouble(SplitPanePositionKey, Double.NaN)
        val value = if (stored.isFinite()) stored.toFloat() else SplitPaneDefaultPosition
        value.coerceIn(0f, 1f)
    }
    val splitPaneState = rememberSplitPaneState(initialPositionPercentage = initialPosition)
    LaunchedEffect(splitPaneState, prefs) {
        snapshotFlow { splitPaneState.positionPercentage }
            .distinctUntilChanged()
            .debounce(SplitPaneSaveDebounceMs)
            .collect { position ->
                prefs.putDouble(SplitPanePositionKey, position.toDouble())
            }
    }
    return splitPaneState
}

@Composable
private fun DetailPane(
    store: NetworkInspectorStore,
    state: DetailPaneState,
    uiStateStore: InspectorUiStateStore,
) {
    when (val content = resolveDetailContent(store, state.selectedItemId)) {
        is DetailContent.Request -> {
            RequestDetailView(request = content.model, uiStateStore = uiStateStore)
            return
        }

        is DetailContent.WebSocket -> {
            WebSocketDetailView(webSocket = content.model, uiStateStore = uiStateStore)
            return
        }

        null -> Unit
    }

    DetailPaneEmptyState(state)
}

private sealed interface DetailContent {
    data class Request(val model: NetworkInspectorRequestUiModel) : DetailContent
    data class WebSocket(val model: NetworkInspectorWebSocketUiModel) : DetailContent
}

private fun resolveDetailContent(
    store: NetworkInspectorStore,
    selection: NetworkInspectorItemId?,
): DetailContent? {
    return when (selection) {
        is NetworkInspectorItemId.Request -> {
            store.requestOrNull(selection.id)
                ?.let { NetworkInspectorRequestUiModel.from(it) }
                ?.let(DetailContent::Request)
        }

        is NetworkInspectorItemId.WebSocket -> {
            store.webSocketOrNull(selection.id)
                ?.let { NetworkInspectorWebSocketUiModel.from(it) }
                ?.let(DetailContent::WebSocket)
        }

        null -> null
    }
}

@Composable
private fun DetailPaneEmptyState(state: DetailPaneState) {
    // Empty / placeholder states.
    val selectedServer = state.selectedServer
    val missingNetworkFeatureServer = selectedServer?.takeIf { server ->
        state.serverScopedItems.isEmpty() && server.hasHello && "network" !in server.features
    }
    when {
        state.servers.isEmpty() -> EmptyState(
            title = "No compatible apps detected",
            body = "Apps must include the `com.openai.snapo` dependencies to appear here.",
        )

        missingNetworkFeatureServer != null -> EmptyState(
            title = "Network Inspector in ${missingNetworkFeatureServer.displayName} not found",
            body = "The server is connected, but the network feature is either not installed or not enabled.",
        )

        state.serverScopedItems.isEmpty() -> {
            val waitingForConnection =
                state.selectedServer == null || !state.selectedServer.hasHello
            if (waitingForConnection) {
                EmptyState(
                    title = "Waiting for connection...",
                    body = "Snap-O is waiting for the app to accept the link connection.",
                    showDocsLink = false,
                )
            } else {
                EmptyState(
                    title = "No activity for this app yet",
                    body = "Requests will appear here once the app makes network calls.",
                    showDocsLink = false,
                )
            }
        }

        else -> EmptyState(
            title = "Select a record",
            body = "Choose an entry to inspect its details.",
            showDocsLink = false,
        )
    }
}

@Composable
private fun EmptyState(
    title: String,
    body: String,
    showDocsLink: Boolean = true,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(Spacings.lg),
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .fillMaxSize()
            .padding(Spacings.huge),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(
            body,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        if (showDocsLink) {
            TextButton(onClick = { openUrl("https://github.com/openai/snap-o/blob/main/docs/network-inspector.md") }) {
                Text("Read the developer guide")
            }
        }
    }
}

private fun openUrl(url: String) {
    runCatching {
        if (Desktop.isDesktopSupported()) {
            Desktop.getDesktop().browse(URI(url))
        }
    }
}

@Composable
private fun SyncSelectedServerEffect(
    servers: List<NetworkInspectorServerUiModel>,
    selectedServerId: SnapOLinkServerId?,
    onSelectedServerIdChange: (SnapOLinkServerId?) -> Unit,
) {
    val latestOnSelectedServerIdChange by rememberUpdatedState(onSelectedServerIdChange)
    LaunchedEffect(servers, selectedServerId) {
        latestOnSelectedServerIdChange(pickSelectedServerId(servers, selectedServerId))
    }
}

@Composable
private fun SyncSelectedItemEffect(
    filteredItems: List<NetworkInspectorListItemUiModel>,
    selectedItemId: NetworkInspectorItemId?,
    onSelectedItemIdChange: (NetworkInspectorItemId?) -> Unit,
) {
    val latestOnSelectedItemIdChange by rememberUpdatedState(onSelectedItemIdChange)
    LaunchedEffect(filteredItems, selectedItemId) {
        latestOnSelectedItemIdChange(pickSelectedItemId(filteredItems, selectedItemId))
    }
}

@Composable
private fun RetainServerEffect(
    store: NetworkInspectorStore,
    selectedServerId: SnapOLinkServerId?,
) {
    LaunchedEffect(selectedServerId) {
        if (selectedServerId != null) {
            store.setRetainedServerIds(setOf(selectedServerId))
            store.notifyFeatureOpened("network", selectedServerId)
        } else {
            store.setRetainedServerIds(emptySet())
        }
    }
}

@Composable
private fun ReplayFeatureEffect(
    store: NetworkInspectorStore,
    selectedServerId: SnapOLinkServerId?,
    servers: List<NetworkInspectorServerUiModel>,
) {
    LaunchedEffect(
        selectedServerId,
        serverConnectionKey(servers),
    ) {
        if (selectedServerId != null) {
            store.notifyFeatureOpened("network", selectedServerId)
        }
    }
}

private fun pickSelectedServerId(
    servers: List<NetworkInspectorServerUiModel>,
    current: SnapOLinkServerId?,
): SnapOLinkServerId? {
    return when {
        servers.isEmpty() -> null
        current != null && servers.any { it.id == current } -> current
        else -> servers.first().id
    }
}

private fun pickSelectedItemId(
    items: List<NetworkInspectorListItemUiModel>,
    current: NetworkInspectorItemId?,
): NetworkInspectorItemId? {
    if (items.isEmpty()) return null
    val ids = items.map { it.id }.toSet()
    return if (current != null && ids.contains(current)) current else items.first().id
}

private fun serverConnectionKey(
    servers: List<NetworkInspectorServerUiModel>,
): List<Triple<SnapOLinkServerId, Boolean, Boolean>> {
    return servers.map { Triple(it.id, it.isConnected, it.hasHello) }
}

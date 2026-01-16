@file:OptIn(
    ExperimentalFoundationApi::class,
    ExperimentalMaterial3ExpressiveApi::class,
)

package com.openai.snapo.desktop.ui.inspector

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ContextMenuArea
import androidx.compose.foundation.ContextMenuItem
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.VerticalScrollbar
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollbarAdapter
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openai.snapo.desktop.generated.resources.Res
import com.openai.snapo.desktop.generated.resources.delete_24px
import com.openai.snapo.desktop.generated.resources.sort_24px
import com.openai.snapo.desktop.generated.resources.sync_24px
import com.openai.snapo.desktop.inspector.ListSortOrder
import com.openai.snapo.desktop.inspector.NetworkInspectorCopyExporter
import com.openai.snapo.desktop.inspector.NetworkInspectorItemId
import com.openai.snapo.desktop.inspector.NetworkInspectorListItemUiModel
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestId
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestStatus
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestSummary
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestUiModel
import com.openai.snapo.desktop.inspector.NetworkInspectorServerUiModel
import com.openai.snapo.desktop.inspector.NetworkInspectorStatusPresentation
import com.openai.snapo.desktop.inspector.NetworkInspectorStore
import com.openai.snapo.desktop.inspector.SnapOLinkServerId
import com.openai.snapo.desktop.ui.theme.SnapOAccents
import com.openai.snapo.desktop.ui.theme.SnapOMono
import com.openai.snapo.desktop.ui.theme.SnapOTheme
import com.openai.snapo.desktop.ui.theme.Spacings
import org.jetbrains.compose.resources.DrawableResource
import org.jetbrains.compose.resources.painterResource
import java.net.URI
import java.time.Instant
import androidx.compose.foundation.lazy.LazyColumn as SidebarLazyColumn

internal data class SidebarState(
    val servers: List<NetworkInspectorServerUiModel>,
    val selectedServer: NetworkInspectorServerUiModel?,
    val serverMenuExpanded: Boolean,
    val items: List<NetworkInspectorListItemUiModel>,
    val serverScopedItems: List<NetworkInspectorListItemUiModel>,
    val filteredItems: List<NetworkInspectorListItemUiModel>,
    val selectedItemId: NetworkInspectorItemId?,
    val searchText: String,
    val sortOrder: ListSortOrder,
)

internal data class SidebarActions(
    val onSelectedServerIdChange: (SnapOLinkServerId) -> Unit,
    val onServerMenuExpandedChange: (Boolean) -> Unit,
    val onSelectedItemIdChange: (NetworkInspectorItemId) -> Unit,
    val onSearchTextChange: (String) -> Unit,
    val onToggleSortOrder: () -> Unit,
    val onClearComplete: () -> Unit,
)

@Composable
internal fun Sidebar(
    state: SidebarState,
    actions: SidebarActions,
    contextMenuItems: (NetworkInspectorListItemUiModel) -> List<ContextMenuItem>,
    modifier: Modifier = Modifier,
    listState: LazyListState? = null,
) {
    val isDark = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val sidebarColor = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHighest
    } else {
        MaterialTheme.colorScheme.surface
    }
    Surface(
        color = sidebarColor,
        tonalElevation = (0.5).dp,
        modifier = modifier,
    ) {
        SidebarContent(
            state = state,
            actions = actions,
            contextMenuItems = contextMenuItems,
            listState = listState,
        )
    }
}

@Composable
private fun SidebarContent(
    state: SidebarState,
    actions: SidebarActions,
    contextMenuItems: (NetworkInspectorListItemUiModel) -> List<ContextMenuItem>,
    listState: LazyListState?,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier) {
        ServerPicker(
            servers = state.servers,
            selectedServer = state.selectedServer,
            onSelectedServerIdChange = actions.onSelectedServerIdChange,
            expanded = state.serverMenuExpanded,
            onExpandedChange = actions.onServerMenuExpandedChange,
            modifier = Modifier.fillMaxWidth().padding(
                start = Spacings.md,
                top = Spacings.mdPlus,
                end = Spacings.md,
            ),
        )

        ReplacementServerBanner(
            servers = state.servers,
            selectedServer = state.selectedServer,
            onSelect = actions.onSelectedServerIdChange,
            modifier = Modifier.fillMaxWidth().padding(horizontal = Spacings.md),
        )

        Spacer(Modifier.size(Spacings.md))

        if (state.selectedServer?.isSchemaNewerThanSupported == true) {
            SchemaWarning(
                server = state.selectedServer,
                modifier = Modifier.fillMaxWidth().padding(horizontal = Spacings.lg)
            )
        }

        SidebarFilterRow(
            searchText = state.searchText,
            onSearchTextChange = actions.onSearchTextChange,
            sortOrder = state.sortOrder,
            hasClearableItems = remember(state.items) { state.items.any { !it.isPending } },
            onToggleSortOrder = actions.onToggleSortOrder,
            onClearComplete = actions.onClearComplete,
            modifier = Modifier.fillMaxWidth().padding(start = Spacings.md, end = Spacings.md),
        )

        Spacer(Modifier.size(Spacings.md))

        SidebarList(
            items = state.items,
            serverScopedItems = state.serverScopedItems,
            filteredItems = state.filteredItems,
            selectedServer = state.selectedServer,
            selectedItemId = state.selectedItemId,
            onSelectedItemIdChange = actions.onSelectedItemIdChange,
            contextMenuItems = contextMenuItems,
            modifier = Modifier.fillMaxWidth().weight(1f),
            listState = listState,
        )
    }
}

@Composable
private fun SidebarFilterRow(
    searchText: String,
    onSearchTextChange: (String) -> Unit,
    sortOrder: ListSortOrder,
    hasClearableItems: Boolean,
    onToggleSortOrder: () -> Unit,
    onClearComplete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Spacings.sm),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier,
    ) {
        val searchTextStyle = MaterialTheme.typography.bodySmallEmphasized
        BasicTextField(
            value = searchText,
            onValueChange = onSearchTextChange,
            textStyle = searchTextStyle.copy(color = MaterialTheme.colorScheme.onSurface),
            singleLine = true,
            modifier = Modifier.weight(1f).border(
                1.dp,
                MaterialTheme.colorScheme.outline,
                shape = MaterialTheme.shapes.extraSmall,
            ),
        ) { innerTextField ->
            Box(modifier = Modifier.padding(horizontal = Spacings.sm, vertical = Spacings.xs)) {
                if (searchText.isEmpty()) {
                    Text(
                        "Filter by URL",
                        style = MaterialTheme.typography.bodySmallEmphasized,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
                innerTextField()
            }
        }

        val sortRotation = if (sortOrder == ListSortOrder.NewestFirst) 180f else 0f
        ToolbarActionGroup {
            ToolbarIconButton(
                onClick = onToggleSortOrder,
                icon = Res.drawable.sort_24px,
                iconRotation = sortRotation,
                contentDescription = "Toggle sort order",
            )
            ToolbarIconButton(
                onClick = onClearComplete,
                enabled = hasClearableItems,
                icon = Res.drawable.delete_24px,
                contentDescription = "Clear completed",
            )
        }
    }
}

@Composable
private fun ReplacementServerBanner(
    servers: List<NetworkInspectorServerUiModel>,
    selectedServer: NetworkInspectorServerUiModel?,
    onSelect: (SnapOLinkServerId) -> Unit,
    modifier: Modifier = Modifier,
) {
    val candidate = remember(servers, selectedServer) {
        val current = selectedServer ?: return@remember null
        if (current.isConnected) return@remember null
        servers.firstOrNull { s ->
            val isSameApp = s.displayName == current.displayName
            val isSameDevice = s.deviceId == current.deviceId
            s.isConnected && s.id != current.id && isSameApp && isSameDevice
        }
    }

    if (candidate != null) {
        Surface(
            onClick = { onSelect(candidate.id) },
            color = SnapOAccents.current().warningSurfaceStrong,
            contentColor = SnapOAccents.current().onWarningSurfaceStrong,
            shape = MaterialTheme.shapes.small,
            modifier = modifier.padding(top = Spacings.md),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = Spacings.mdPlus, vertical = Spacings.md),
            ) {
                Column {
                    Text(
                        "New process available",
                        style = MaterialTheme.typography.titleSmallEmphasized,
                    )
                    Text(
                        "PID ${candidate.pid}",
                        color = LocalContentColor.current.copy(alpha = 0.85f),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                Spacer(Modifier.weight(1f))
                Icon(
                    painterResource(Res.drawable.sync_24px),
                    contentDescription = null,
                    modifier = Modifier.padding(0.dp).size(20.dp),
                )
            }
        }
    }
}

@Composable
private fun SchemaWarning(
    server: NetworkInspectorServerUiModel,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = SnapOAccents.current().warningSurface,
        shape = MaterialTheme.shapes.medium,
        modifier = modifier,
    ) {
        Column(modifier = Modifier.padding(Spacings.lg)) {
            val versionText = server.schemaVersion?.toString() ?: "unknown"
            Text("App reports schema v$versionText", style = MaterialTheme.typography.bodyMedium)
            Text(
                "This Android build may be newer than the Network Inspector understands.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SidebarList(
    items: List<NetworkInspectorListItemUiModel>,
    serverScopedItems: List<NetworkInspectorListItemUiModel>,
    filteredItems: List<NetworkInspectorListItemUiModel>,
    selectedServer: NetworkInspectorServerUiModel?,
    selectedItemId: NetworkInspectorItemId?,
    onSelectedItemIdChange: (NetworkInspectorItemId) -> Unit,
    contextMenuItems: (NetworkInspectorListItemUiModel) -> List<ContextMenuItem>,
    modifier: Modifier = Modifier,
    listState: LazyListState? = null,
) {
    val placeholder = sidebarPlaceholderText(
        items = items,
        serverScopedItems = serverScopedItems,
        filteredItems = filteredItems,
        selectedServer = selectedServer,
    )

    if (placeholder != null) {
        Text(
            text = placeholder,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = Spacings.md, start = Spacings.mdPlus, end = Spacings.mdPlus),
        )
        return
    }

    val resolvedListState = listState ?: rememberLazyListState()
    SidebarListContent(
        items = filteredItems,
        selectedItemId = selectedItemId,
        onSelectedItemIdChange = onSelectedItemIdChange,
        listState = resolvedListState,
        contextMenuItems = contextMenuItems,
        modifier = modifier,
    )
}

@Composable
private fun SidebarListContent(
    items: List<NetworkInspectorListItemUiModel>,
    selectedItemId: NetworkInspectorItemId?,
    onSelectedItemIdChange: (NetworkInspectorItemId) -> Unit,
    listState: LazyListState,
    contextMenuItems: (NetworkInspectorListItemUiModel) -> List<ContextMenuItem>,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier) {
        val showTopFade by remember(listState) {
            derivedStateOf {
                listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 0
            }
        }
        SidebarLazyColumn(
            contentPadding = PaddingValues(bottom = Spacings.lg),
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .sidebarTopFade(canScrollBackward = showTopFade),
        ) {
            items(items, key = { it.id.hashCode() }) { item ->
                val isSelected = selectedItemId == item.id
                ContextMenuArea(
                    items = { contextMenuItems(item) },
                ) {
                    SidebarRow(
                        item = item,
                        selected = isSelected,
                        onClick = { onSelectedItemIdChange(item.id) },
                    )
                }
            }
        }
        VerticalScrollbar(
            adapter = rememberScrollbarAdapter(listState),
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .fillMaxHeight(),
        )
    }
}

private fun sidebarPlaceholderText(
    items: List<NetworkInspectorListItemUiModel>,
    serverScopedItems: List<NetworkInspectorListItemUiModel>,
    filteredItems: List<NetworkInspectorListItemUiModel>,
    selectedServer: NetworkInspectorServerUiModel?,
): String? {
    return when {
        items.isEmpty() -> "No activity yet"
        serverScopedItems.isEmpty() -> {
            if (selectedServer == null || !selectedServer.hasHello) {
                "Waiting for connection..."
            } else {
                "No activity for this app yet"
            }
        }

        filteredItems.isEmpty() -> "No matches"
        else -> null
    }
}

internal fun sidebarContextMenuItems(
    store: NetworkInspectorStore,
    item: NetworkInspectorListItemUiModel,
): List<ContextMenuItem> {
    return when (val kind = item.kind) {
        is NetworkInspectorListItemUiModel.Kind.Request -> listOf(
            ContextMenuItem("Copy URL") {
                NetworkInspectorCopyExporter.copyUrl(kind.value.url)
            },
            ContextMenuItem("Copy as cURL") {
                val model = store.requestOrNull(kind.value.id)
                    ?.let { NetworkInspectorRequestUiModel.from(it) }
                if (model != null) NetworkInspectorCopyExporter.copyCurl(model)
            },
        )

        is NetworkInspectorListItemUiModel.Kind.WebSocket -> emptyList()
    }
}

@Composable
private fun Modifier.sidebarTopFade(
    canScrollBackward: Boolean,
    height: Dp = 8.dp,
): Modifier {
    val targetAlpha = if (canScrollBackward) 1f else 0f
    val animatedAlpha by animateFloatAsState(targetValue = targetAlpha, label = "SidebarTopFade")
    val topColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    return drawWithContent {
        drawContent()
        if (animatedAlpha > 0f) {
            val heightPx = height.toPx()
            drawRect(
                brush = Brush.verticalGradient(
                    0f to topColor,
                    1f to Color.Transparent,
                    endY = heightPx,
                ),
                size = size.copy(height = heightPx),
                alpha = animatedAlpha,
            )
        }
    }
}

@Composable
private fun SidebarRow(
    item: NetworkInspectorListItemUiModel,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val hovered by interactionSource.collectIsHoveredAsState()
    val pressed by interactionSource.collectIsPressedAsState()
    val accents = SnapOAccents.current()
    val selectedBackground = accents.sidebarSelection
    val bg = when {
        selected -> selectedBackground
        pressed -> MaterialTheme.colorScheme.surfaceContainerHigh
        hovered -> MaterialTheme.colorScheme.surfaceContainerLow
        else -> Color.Transparent
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Spacings.md),
        modifier = Modifier
            .fillMaxWidth()
            .background(bg)
            .hoverable(interactionSource)
            .clickable(interactionSource = interactionSource, onClick = onClick)
            .padding(horizontal = Spacings.lg, vertical = Spacings.sm),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = item.primaryPathComponent,
                style = MaterialTheme.typography.bodySmallEmphasized,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (item.secondaryPath.isNotBlank()) {
                Text(
                    text = item.secondaryPath,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Normal,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Text(
            text = item.method,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontFamily = SnapOMono,
        )

        StatusView(item)
    }
}

@Composable
private fun ToolbarActionGroup(
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Spacings.xxs),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
        modifier = modifier,
    )
}

@Composable
private fun ToolbarIconButton(
    onClick: () -> Unit,
    icon: DrawableResource,
    contentDescription: String,
    enabled: Boolean = true,
    iconRotation: Float = 0f,
) {
    // Desktop-leaning icon buttons: smaller than Material's default.
    val interactionSource = remember { MutableInteractionSource() }
    val hovered by interactionSource.collectIsHoveredAsState()
    val pressed by interactionSource.collectIsPressedAsState()
    val bg = when {
        pressed && enabled -> MaterialTheme.colorScheme.surfaceContainerHighest
        hovered && enabled -> MaterialTheme.colorScheme.surfaceContainerHigh
        else -> Color.Transparent
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(28.dp)
            .hoverable(interactionSource)
            .background(bg, shape = MaterialTheme.shapes.extraSmall)
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            ),
    ) {
        Icon(
            painter = painterResource(icon),
            contentDescription = contentDescription,
            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else 0.4f),
            modifier = Modifier.size(16.dp).rotate(iconRotation),
        )
    }
}

@Composable
private fun StatusView(item: NetworkInspectorListItemUiModel) {
    if (item.showsActiveIndicator) {
        Text("●", color = SnapOAccents.current().success)
        return
    }

    when (val status = item.status) {
        is NetworkInspectorRequestStatus.Pending -> {
            CircularProgressIndicator(
                strokeWidth = 2.dp,
                modifier = Modifier.size(12.dp),
            )
        }

        is NetworkInspectorRequestStatus.Success -> {
            val color = NetworkInspectorStatusPresentation.color(status.code)
            Text(status.code.toString(), color = color, style = MaterialTheme.typography.labelSmall)
        }

        is NetworkInspectorRequestStatus.Failure -> {
            Text(
                "Error",
                color = SnapOAccents.current().error,
                style = MaterialTheme.typography.labelSmall,
                maxLines = 1
            )
        }
    }
}

@Preview(name = "Sidebar Selected - 3 Items")
@Composable
private fun SidebarSelectedShortListPreview() {
    val server = previewServer(idSuffix = "primary", isConnected = true)
    val items = listOf(
        previewRequestItem(
            index = 1,
            serverId = server.id,
            method = "GET",
            url = "https://api.example.com/v1/sessions?cursor=latest",
            status = NetworkInspectorRequestStatus.Success(200),
        ),
        previewRequestItem(
            index = 2,
            serverId = server.id,
            method = "POST",
            url = "https://api.example.com/v1/feedback",
            status = NetworkInspectorRequestStatus.Pending,
            isStreaming = true,
            hasClosedStream = false,
        ),
        previewRequestItem(
            index = 3,
            serverId = server.id,
            method = "DELETE",
            url = "https://api.example.com/v1/snapshots?limit=1",
            status = NetworkInspectorRequestStatus.Failure("Timeout"),
        ),
    )
    SidebarPreviewFrame(
        state = previewSidebarState(
            servers = listOf(server),
            selectedServer = server,
            items = items,
            selectedItemId = items[1].id,
        ),
    )
}

@Preview(name = "Sidebar Selected - Scrolled")
@Composable
private fun SidebarSelectedScrolledPreview() {
    val server = previewServer(idSuffix = "primary", isConnected = true)
    val items = previewRequestList(server.id, count = 24)
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = (items.size - 6).coerceAtLeast(0),
    )
    SidebarPreviewFrame(
        state = previewSidebarState(
            servers = listOf(server),
            selectedServer = server,
            items = items,
            selectedItemId = items.last().id,
        ),
        listState = listState,
    )
}

@Preview(name = "Sidebar No Selection")
@Composable
private fun SidebarNoSelectedProcessPreview() {
    val server = previewServer(idSuffix = "primary", isConnected = true)
    SidebarPreviewFrame(
        state = previewSidebarState(
            servers = listOf(server),
            selectedServer = null,
            items = emptyList(),
            selectedItemId = null,
        ),
    )
}

@Preview(name = "Sidebar New Process Available")
@Composable
private fun SidebarNewProcessAvailablePreview() {
    val disconnected = previewServer(idSuffix = "old", isConnected = false)
    val replacement = previewServer(idSuffix = "new", isConnected = true)
    val items = previewRequestList(disconnected.id, count = 3)
    SidebarPreviewFrame(
        state = previewSidebarState(
            servers = listOf(disconnected, replacement),
            selectedServer = disconnected,
            items = items,
            selectedItemId = items.first().id,
        ),
    )
}

@Preview(name = "Sidebar Empty State")
@Composable
private fun SidebarEmptyStatePreview() {
    val server = previewServer(idSuffix = "primary", isConnected = true)
    SidebarPreviewFrame(
        state = previewSidebarState(
            servers = listOf(server),
            selectedServer = server,
            items = emptyList(),
            selectedItemId = null,
        ),
    )
}

@Composable
private fun SidebarPreviewFrame(
    state: SidebarState,
    listState: LazyListState? = null,
) {
    SnapOTheme(useDarkTheme = false) {
        Surface(modifier = Modifier.size(320.dp, 640.dp)) {
            Box(modifier = Modifier.fillMaxSize().padding(Spacings.lg)) {
                Sidebar(
                    state = state,
                    actions = previewSidebarActions(),
                    contextMenuItems = { emptyList() },
                    modifier = Modifier.fillMaxSize(),
                    listState = listState,
                )
            }
        }
    }
}

private fun previewSidebarActions(): SidebarActions {
    return SidebarActions(
        onSelectedServerIdChange = {},
        onServerMenuExpandedChange = {},
        onSelectedItemIdChange = {},
        onSearchTextChange = {},
        onToggleSortOrder = {},
        onClearComplete = {},
    )
}

private fun previewServer(
    idSuffix: String,
    displayName: String = "com.openai.snapo.demo",
    deviceId: String = "emulator-5554",
    deviceDisplayTitle: String = "Pixel 8 Pro (API 34)",
    isConnected: Boolean = true,
): NetworkInspectorServerUiModel {
    return NetworkInspectorServerUiModel(
        id = SnapOLinkServerId(deviceId = deviceId, socketName = "snapo_server_$idSuffix"),
        displayName = displayName,
        deviceDisplayTitle = deviceDisplayTitle,
        isConnected = isConnected,
        deviceId = deviceId,
        pid = 1234,
        appIconBase64 = null,
        schemaVersion = 2,
        isSchemaNewerThanSupported = false,
        hasHello = true,
        features = setOf("network"),
    )
}

private fun previewRequestList(
    serverId: SnapOLinkServerId,
    count: Int,
): List<NetworkInspectorListItemUiModel> {
    val endpoints = listOf("sessions", "traces", "files", "snapshots")
    val methods = listOf("GET", "POST", "PUT", "DELETE")
    return List(count) { index ->
        val endpoint = endpoints[index % endpoints.size]
        val method = methods[index % methods.size]
        val status = when (index % 4) {
            0 -> NetworkInspectorRequestStatus.Success(200)
            1 -> NetworkInspectorRequestStatus.Success(204)
            2 -> NetworkInspectorRequestStatus.Pending
            else -> NetworkInspectorRequestStatus.Failure("Timeout")
        }
        previewRequestItem(
            index = index + 1,
            serverId = serverId,
            method = method,
            url = "https://api.example.com/v1/$endpoint?page=${index + 1}",
            status = status,
        )
    }
}

private fun previewRequestItem(
    index: Int,
    serverId: SnapOLinkServerId,
    method: String,
    url: String,
    status: NetworkInspectorRequestStatus,
    isStreaming: Boolean = false,
    hasClosedStream: Boolean = true,
): NetworkInspectorListItemUiModel {
    val (primary, secondary) = previewSplitPath(url)
    val seenAt = Instant.parse("2024-06-01T12:00:00Z").plusSeconds(index.toLong())
    val summary = NetworkInspectorRequestSummary(
        id = NetworkInspectorRequestId(serverId = serverId, requestId = "req-$index"),
        serverId = serverId,
        method = method,
        url = url,
        primaryPathComponent = primary,
        secondaryPath = secondary,
        status = status,
        isStreamingResponse = isStreaming,
        hasClosedStream = hasClosedStream,
        firstSeenAt = seenAt,
        lastUpdatedAt = seenAt,
    )
    return NetworkInspectorListItemUiModel(
        kind = NetworkInspectorListItemUiModel.Kind.Request(summary),
        firstSeenAt = summary.firstSeenAt,
    )
}

private fun previewSidebarState(
    servers: List<NetworkInspectorServerUiModel>,
    selectedServer: NetworkInspectorServerUiModel?,
    items: List<NetworkInspectorListItemUiModel>,
    selectedItemId: NetworkInspectorItemId?,
    searchText: String = "",
    sortOrder: ListSortOrder = ListSortOrder.NewestFirst,
): SidebarState {
    val serverScopedItems = items.filter { selectedServer == null || it.serverId == selectedServer.id }
    val filteredItems = filterItemsByUrlSearch(serverScopedItems, searchText)
    return SidebarState(
        servers = servers,
        selectedServer = selectedServer,
        serverMenuExpanded = false,
        items = items,
        serverScopedItems = serverScopedItems,
        filteredItems = filteredItems,
        selectedItemId = selectedItemId,
        searchText = searchText,
        sortOrder = sortOrder,
    )
}

private fun previewSplitPath(url: String): Pair<String, String> {
    val uri = runCatching { URI(url) }.getOrNull() ?: return url to ""
    val path = uri.path.orEmpty()
    val query = uri.rawQuery.orEmpty()
    val querySuffix = if (query.isNotEmpty()) "?$query" else ""
    if (path.isNotBlank()) {
        val parts = path.split('/').filter { it.isNotBlank() }
        val primary = (parts.lastOrNull() ?: path) + querySuffix
        val remaining = parts.dropLast(1)
        val secondary = when {
            remaining.isNotEmpty() -> "/" + remaining.joinToString("/")
            parts.isNotEmpty() -> "/"
            else -> ""
        }
        return primary to secondary
    }
    val primary = (uri.host ?: url) + querySuffix
    return primary to ""
}

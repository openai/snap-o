@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.openai.snapo.desktop.generated.resources.Res
import com.openai.snapo.desktop.generated.resources.arrow_drop_down_24px
import com.openai.snapo.desktop.inspector.NetworkInspectorServerUiModel
import com.openai.snapo.desktop.inspector.SnapOLinkServerId
import com.openai.snapo.desktop.ui.SnapODropdownMenu
import com.openai.snapo.desktop.ui.SnapODropdownMenuHeader
import com.openai.snapo.desktop.ui.theme.SnapOAccents
import com.openai.snapo.desktop.ui.theme.SnapOTheme
import com.openai.snapo.desktop.ui.theme.Spacings
import org.jetbrains.compose.resources.painterResource
import org.jetbrains.skia.Image
import java.util.Base64

@Composable
internal fun ServerPicker(
    servers: List<NetworkInspectorServerUiModel>,
    selectedServer: NetworkInspectorServerUiModel?,
    onSelectedServerIdChange: (SnapOLinkServerId) -> Unit,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (servers.isEmpty()) {
        NoServersFoundBanner(modifier = modifier.fillMaxWidth())
        return
    }

    var anchorWidth by remember { mutableIntStateOf(0) }
    Box(modifier = modifier.onSizeChanged { anchorWidth = it.width }) {
        ServerPickerButton(
            selectedServer = selectedServer,
            expanded = expanded,
            onExpandedChange = onExpandedChange,
        )
        ServerPickerMenu(
            servers = servers,
            expanded = expanded,
            onExpandedChange = onExpandedChange,
            onSelectedServerIdChange = onSelectedServerIdChange,
            modifier = Modifier.width(with(LocalDensity.current) { anchorWidth.toDp() }),
        )
    }
}

@Composable
private fun NoServersFoundBanner(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .background(
                MaterialTheme.colorScheme.surfaceVariant,
                shape = MaterialTheme.shapes.medium
            )
            .padding(Spacings.lg),
    ) {
        Text(
            "No Apps Found",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun ServerPickerButton(
    selectedServer: NetworkInspectorServerUiModel?,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
) {
    OutlinedButton(
        onClick = { onExpandedChange(!expanded) },
        shape = MaterialTheme.shapes.small,
        contentPadding = PaddingValues(horizontal = Spacings.lg, vertical = Spacings.md),
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = MaterialTheme.colorScheme.surface,
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        border = BorderStroke(1.0.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth(),
    ) {
        val iconBitmap = remember(selectedServer?.id, selectedServer?.appIconBase64) {
            decodeBase64ImageBitmapOrNull(selectedServer?.appIconBase64)
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            ServerAppIcon(
                icon = iconBitmap,
                modifier = Modifier.size(AppIconSize),
                connectionStatus = selectedServer?.isConnected,
            )
            Spacer(Modifier.width(Spacings.lg))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = selectedServer?.displayName ?: "Select an App",
                    style = MaterialTheme.typography.titleSmallEmphasized,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!selectedServer?.deviceDisplayTitle.isNullOrEmpty()) {
                    Text(
                        text = selectedServer.deviceDisplayTitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.width(Spacings.mdPlus))
            Icon(
                painter = painterResource(Res.drawable.arrow_drop_down_24px),
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .size(18.dp)
                    .rotate(if (expanded) 180f else 0f),
            )
        }
    }
}

@Composable
private fun ServerPickerMenu(
    servers: List<NetworkInspectorServerUiModel>,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onSelectedServerIdChange: (SnapOLinkServerId) -> Unit,
    modifier: Modifier = Modifier,
) {
    SnapODropdownMenu(
        expanded = expanded,
        onDismissRequest = { onExpandedChange(false) },
        modifier = modifier,
    ) {
        SnapODropdownMenuHeader(text = "Detected servers")
        servers.forEach { server ->
            val iconBitmap = remember(server.id, server.appIconBase64) {
                decodeBase64ImageBitmapOrNull(server.appIconBase64)
            }
            DropdownMenuItem(
                text = {
                    Column {
                        Text(
                            server.displayName,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            server.deviceDisplayTitle,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                },
                leadingIcon = {
                    ServerAppIcon(
                        icon = iconBitmap,
                        modifier = Modifier.size(AppIconSize),
                        connectionStatus = server.isConnected,
                    )
                },
                onClick = {
                    onSelectedServerIdChange(server.id)
                    onExpandedChange(false)
                },
            )
        }
    }
}

@Composable
private fun ServerAppIcon(
    icon: ImageBitmap?,
    modifier: Modifier = Modifier,
    connectionStatus: Boolean? = null,
) {
    Box(modifier = modifier) {
        val accents = SnapOAccents.current()
        val shape = MaterialTheme.shapes.extraSmall
        if (icon != null) {
            Image(
                bitmap = icon,
                contentDescription = null,
                modifier = Modifier.matchParentSize().clip(shape),
            )
        } else {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .clip(shape)
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh),
            )
        }
        if (connectionStatus != null) {
            val statusColor = if (connectionStatus) accents.success else accents.info
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(1.dp)
                    .size(AppIconStatusSize)
                    .background(statusColor, CircleShape)
                    .border(1.dp, MaterialTheme.colorScheme.surface, CircleShape),
            )
        }
    }
}

private fun decodeBase64ImageBitmapOrNull(base64: String?): ImageBitmap? {
    if (base64.isNullOrBlank()) return null
    val bytes = runCatching { Base64.getDecoder().decode(base64) }.getOrNull() ?: return null
    return try {
        Image.makeFromEncoded(bytes).toComposeImageBitmap()
    } catch (_: Throwable) {
        null
    }
}

private val AppIconSize = 32.dp
private val AppIconStatusSize = 8.dp

@Preview
@Composable
private fun ServerPickerButtonPreview() {
    SnapOTheme(useDarkTheme = false) {
        val server = NetworkInspectorServerUiModel(
            id = SnapOLinkServerId(deviceId = "emulator-5554", socketName = "snapo_server_1234"),
            displayName = "com.openai.snapo.demo",
            deviceDisplayTitle = "Pixel 8 Pro (API 34)",
            isConnected = true,
            deviceId = "emulator-5554",
            pid = 1234,
            appIconBase64 = null,
            schemaVersion = 2,
            isSchemaNewerThanSupported = false,
            isSchemaOlderThanSupported = false,
            hasHello = true,
            features = setOf("network"),
        )
        Box(modifier = Modifier.width(320.dp).padding(Spacings.lg)) {
            ServerPickerButton(
                selectedServer = server,
                expanded = false,
                onExpandedChange = {},
            )
        }
    }
}

@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.ContextMenuArea
import androidx.compose.foundation.ContextMenuItem
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestUiModel
import com.openai.snapo.desktop.ui.TriangleIndicator
import com.openai.snapo.desktop.ui.json.JsonOutlineExpansionState
import com.openai.snapo.desktop.ui.theme.Spacings
import java.awt.FileDialog
import java.awt.Frame
import java.awt.Toolkit
import java.awt.datatransfer.DataFlavor
import java.awt.datatransfer.Transferable
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import javax.imageio.ImageIO
import org.jetbrains.skia.Image as SkiaImage

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun BodySection(
    title: String,
    payload: NetworkInspectorRequestUiModel.BodyPayload,
    isExpanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    usePrettyPrinted: Boolean,
    onPrettyPrintedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    jsonOutlineState: JsonOutlineExpansionState? = null,
) {
    Column(
        verticalArrangement = Arrangement.spacedBy(Spacings.sm),
        modifier = modifier,
    ) {
        BodySectionHeader(
            title = title,
            payload = payload,
            isExpanded = isExpanded,
            onExpandedChange = onExpandedChange,
        )

        if (isExpanded) {
            BodySectionContent(
                payload = payload,
                usePrettyPrinted = usePrettyPrinted,
                onPrettyPrintedChange = onPrettyPrintedChange,
                jsonOutlineState = jsonOutlineState,
            )
        }
    }
}

@Composable
private fun BodySectionHeader(
    title: String,
    payload: NetworkInspectorRequestUiModel.BodyPayload,
    isExpanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable(interactionSource = null, indication = null) { onExpandedChange(!isExpanded) }
            .padding(vertical = Spacings.xs),
    ) {
        TriangleIndicator(expanded = isExpanded)
        Spacer(Modifier.size(Spacings.xxs))
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmallEmphasized,
            modifier = Modifier
                .weight(1f)
                .padding(end = Spacings.md),
        )
        val metadata = remember(payload) { metadataText(payload) }
        if (metadata != null) {
            Text(
                text = metadata,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun BodySectionContent(
    payload: NetworkInspectorRequestUiModel.BodyPayload,
    usePrettyPrinted: Boolean,
    onPrettyPrintedChange: (Boolean) -> Unit,
    jsonOutlineState: JsonOutlineExpansionState?,
) {
    val imageBitmap = remember(payload.data) { payload.data?.let(::decodeImageBitmap) }
    val bytes = payload.data
    if (imageBitmap != null && bytes != null) {
        BodyImagePreview(
            payload = payload,
            imageBitmap = imageBitmap,
            bytes = bytes,
        )
    } else {
        BodyTextPayload(
            payload = payload,
            usePrettyPrinted = usePrettyPrinted,
            onPrettyPrintedChange = onPrettyPrintedChange,
            jsonOutlineState = jsonOutlineState,
        )
    }
}

@Composable
private fun BodyImagePreview(
    payload: NetworkInspectorRequestUiModel.BodyPayload,
    imageBitmap: ImageBitmap,
    bytes: ByteArray,
) {
    InspectorCard(modifier = Modifier.padding(top = Spacings.md)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Image preview", style = MaterialTheme.typography.titleSmallEmphasized)
            Spacer(Modifier.weight(1f))
            Text(
                text = payload.contentType?.uppercase() ?: "",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        ContextMenuArea(
            items = {
                listOf(
                    ContextMenuItem("Copy Image") { copyImage(bytes) },
                    ContextMenuItem("Save As...") { saveBytesToFile(bytes, payload.contentType) },
                )
            },
        ) {
            Image(
                bitmap = imageBitmap,
                contentDescription = null,
                modifier = Modifier
                    .padding(top = Spacings.md)
                    .fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun BodyTextPayload(
    payload: NetworkInspectorRequestUiModel.BodyPayload,
    usePrettyPrinted: Boolean,
    onPrettyPrintedChange: (Boolean) -> Unit,
    jsonOutlineState: JsonOutlineExpansionState?,
) {
    InspectorCard {
        InspectorPayloadView(
            rawText = payload.rawText,
            prettyText = payload.prettyPrintedText,
            isLikelyJson = payload.isLikelyJson,
            usePrettyPrinted = usePrettyPrinted,
            onPrettyPrintedChange = onPrettyPrintedChange,
            jsonOutlineState = jsonOutlineState,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

private fun metadataText(payload: NetworkInspectorRequestUiModel.BodyPayload): String? {
    val parts = mutableListOf<String>()

    if (payload.capturedBytes > 0) {
        parts += "Captured ${formatBytes(payload.capturedBytes)}"
        payload.totalBytes?.let { parts += "of ${formatBytes(it)}" }
    } else if (payload.totalBytes != null) {
        parts += "Total ${formatBytes(payload.totalBytes)}"
    }

    val truncated = payload.truncatedBytes
    if (truncated != null) {
        when {
            truncated > 0 -> parts += "(${formatBytes(truncated)} truncated)"
            truncated == 0L && !payload.isPreview -> parts += "(complete)"
        }
    } else if (payload.isPreview) {
        parts += "(preview)"
    }

    return parts.takeIf { it.isNotEmpty() }?.joinToString(" ")
}

private fun formatBytes(byteCount: Long): String {
    val kib = 1024.0
    val mib = kib * 1024.0
    val gib = mib * 1024.0

    val value = byteCount.toDouble()
    return when {
        value < kib -> "$byteCount B"
        value < mib -> "%.1f KiB".format(value / kib)
        value < gib -> "%.1f MiB".format(value / mib)
        else -> "%.1f GiB".format(value / gib)
    }
}

private fun decodeImageBitmap(bytes: ByteArray): ImageBitmap? {
    return try {
        SkiaImage.makeFromEncoded(bytes).toComposeImageBitmap()
    } catch (_: Throwable) {
        null
    }
}

private fun copyImage(bytes: ByteArray) {
    val image = runCatching { ImageIO.read(ByteArrayInputStream(bytes)) }.getOrNull() ?: return
    val clipboard = Toolkit.getDefaultToolkit().systemClipboard
    clipboard.setContents(
        object : Transferable {
            override fun getTransferDataFlavors(): Array<DataFlavor> = arrayOf(DataFlavor.imageFlavor)
            override fun isDataFlavorSupported(flavor: DataFlavor): Boolean = flavor == DataFlavor.imageFlavor
            override fun getTransferData(flavor: DataFlavor): Any = image
        },
        null,
    )
}

private fun saveBytesToFile(bytes: ByteArray, contentType: String?) {
    val dialog = FileDialog(null as Frame?, "Save As", FileDialog.SAVE)
    val ext = when {
        contentType?.startsWith("image/png") == true -> "png"
        contentType?.startsWith("image/jpeg") == true || contentType?.startsWith("image/jpg") == true -> "jpg"
        contentType?.startsWith("image/webp") == true -> "webp"
        contentType?.startsWith("image/gif") == true -> "gif"
        else -> null
    }
    dialog.file = if (ext != null) "image.$ext" else "image"
    dialog.isVisible = true

    val directory = dialog.directory ?: return
    val fileName = dialog.file ?: return
    val outFile = File(directory, fileName)
    FileOutputStream(outFile).use { it.write(bytes) }
}

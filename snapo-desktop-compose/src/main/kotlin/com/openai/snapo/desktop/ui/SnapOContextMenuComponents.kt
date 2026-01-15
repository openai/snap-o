package com.openai.snapo.desktop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openai.snapo.desktop.ui.theme.Spacings

@Composable
internal fun SnapOContextMenuSurface(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .clip(SnapOMenuDefaults.shape)
            .background(SnapOMenuDefaults.containerColor)
            .border(SnapOMenuDefaults.border, SnapOMenuDefaults.shape)
            .width(IntrinsicSize.Max)
            .verticalScroll(rememberScrollState()),
        content = content,
    )
}

@Composable
internal fun SnapOContextMenuItem(
    label: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    val interactionSource = remember { MutableInteractionSource() }
    val hovered by interactionSource.collectIsHoveredAsState()
    val pressed by interactionSource.collectIsPressedAsState()
    val containerColor = SnapOMenuDefaults.containerColor
    val backgroundColor = when {
        !enabled -> containerColor
        pressed -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
        hovered -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
        else -> containerColor
    }
    val textColor = if (enabled) {
        MaterialTheme.colorScheme.onBackground
    } else {
        MaterialTheme.colorScheme.onBackground.copy(alpha = 0.38f)
    }

    Box(
        contentAlignment = Alignment.CenterStart,
        modifier = Modifier
            .background(backgroundColor)
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                role = Role.Button,
                onClick = onClick,
            )
            .fillMaxWidth()
            .defaultMinSize(minHeight = 32.dp)
            .padding(horizontal = Spacings.lg),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
            color = textColor,
        )
    }
}

@Composable
internal fun SnapOContextMenuSeparator(
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = Spacings.xs)
            .height(1.dp)
            .background(MaterialTheme.colorScheme.outlineVariant),
    )
}

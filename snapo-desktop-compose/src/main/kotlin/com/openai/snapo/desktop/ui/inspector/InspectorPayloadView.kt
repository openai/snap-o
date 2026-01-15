@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openai.snapo.desktop.generated.resources.Res
import com.openai.snapo.desktop.generated.resources.check_24px
import com.openai.snapo.desktop.generated.resources.content_copy_24px
import com.openai.snapo.desktop.inspector.NetworkInspectorCopyExporter
import com.openai.snapo.desktop.ui.json.JsonOutlineExpansionState
import com.openai.snapo.desktop.ui.json.JsonOutlineNode
import com.openai.snapo.desktop.ui.json.JsonOutlineView
import com.openai.snapo.desktop.ui.theme.SnapOMono
import com.openai.snapo.desktop.ui.theme.Spacings
import kotlinx.coroutines.delay
import org.jetbrains.compose.resources.DrawableResource
import org.jetbrains.compose.resources.painterResource

@Composable
fun InspectorPayloadView(
    rawText: String,
    prettyText: String?,
    isLikelyJson: Boolean,
    usePrettyPrinted: Boolean,
    onPrettyPrintedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    showsToggle: Boolean = true,
    showsCopyButton: Boolean = true,
    prettyInitiallyExpanded: Boolean = true,
    jsonOutlineState: JsonOutlineExpansionState? = null,
) {
    val prettyState = rememberPrettyToggleState(
        usePrettyPrinted = usePrettyPrinted,
        onPrettyPrintedChange = onPrettyPrintedChange,
    )
    val derived = rememberInspectorPayloadDerived(
        localPretty = prettyState.isPretty,
        prettyText = prettyText,
        rawText = rawText,
        showsToggle = showsToggle,
        showsCopyButton = showsCopyButton,
        isLikelyJson = isLikelyJson,
    )
    val copyFeedback = rememberCopyFeedback(displayText = derived.displayText, copyKey = derived.payloadKey)
    val onCopy = copyFeedback.onCopy

    Column(
        verticalArrangement = Arrangement.spacedBy(Spacings.sm),
        modifier = modifier,
    ) {
        InspectorPayloadControls(
            showInlineActionsInJsonOutline = derived.showInlineActionsInJsonOutline,
            hasToggle = derived.hasToggle,
            prettyChecked = prettyState.isPretty,
            onPrettyToggle = prettyState.onTogglePretty,
            hasCopy = derived.hasCopy,
            didCopy = copyFeedback.didCopy,
            onCopy = onCopy,
        )
        JsonParseFailureHint(show = derived.showJsonParseFailureHint)
        InspectorPayloadBodySection(
            derived = derived,
            prettyText = prettyText,
            prettyState = prettyState,
            didCopy = copyFeedback.didCopy,
            prettyInitiallyExpanded = prettyInitiallyExpanded,
            jsonOutlineState = jsonOutlineState,
            onCopy = onCopy,
        )
    }
}

@Composable
private fun InspectorPayloadControls(
    showInlineActionsInJsonOutline: Boolean,
    hasToggle: Boolean,
    prettyChecked: Boolean,
    onPrettyToggle: () -> Unit,
    hasCopy: Boolean,
    didCopy: Boolean,
    onCopy: () -> Unit,
) {
    if (showInlineActionsInJsonOutline) return
    ControlsRow(
        hasToggle = hasToggle,
        prettyChecked = prettyChecked,
        onPrettyToggle = onPrettyToggle,
        showsCopyButton = hasCopy,
        didCopy = didCopy,
        onCopy = onCopy,
    )
}

@Composable
private fun InspectorPayloadBodySection(
    derived: InspectorPayloadDerived,
    prettyText: String?,
    prettyState: PrettyToggleState,
    didCopy: Boolean,
    prettyInitiallyExpanded: Boolean,
    jsonOutlineState: JsonOutlineExpansionState?,
    onCopy: () -> Unit,
) {
    val bodyState = InspectorPayloadBodyState(
        displayText = derived.displayText,
        prettyText = prettyText,
        jsonRoot = derived.jsonRoot,
        showsJsonOutline = derived.showsJsonOutline,
        showInlineActionsInJsonOutline = derived.showInlineActionsInJsonOutline,
        hasToggle = derived.hasToggle,
        hasCopy = derived.hasCopy,
        localPretty = prettyState.isPretty,
        didCopy = didCopy,
        prettyInitiallyExpanded = prettyInitiallyExpanded,
        payloadKey = derived.payloadKey,
        jsonOutlineState = jsonOutlineState,
    )
    val bodyActions = InspectorPayloadBodyActions(
        onTogglePretty = prettyState.onTogglePretty,
        onCopy = onCopy,
    )
    InspectorPayloadBody(
        state = bodyState,
        actions = bodyActions,
    )
}

private data class InspectorPayloadDerived(
    val displayText: String,
    val hasToggle: Boolean,
    val hasCopy: Boolean,
    val jsonRoot: JsonOutlineNode?,
    val payloadKey: Int,
    val showsJsonOutline: Boolean,
    val showInlineActionsInJsonOutline: Boolean,
    val showJsonParseFailureHint: Boolean,
)

@Composable
private fun rememberInspectorPayloadDerived(
    localPretty: Boolean,
    prettyText: String?,
    rawText: String,
    showsToggle: Boolean,
    showsCopyButton: Boolean,
    isLikelyJson: Boolean,
): InspectorPayloadDerived {
    val displayText = displayTextFor(localPretty, prettyText, rawText)
    val payloadKey = remember(prettyText, rawText) { (prettyText ?: rawText).hashCode() }
    val hasToggle = hasToggle(showsToggle, prettyText)
    val hasCopy = hasCopy(showsCopyButton, displayText)
    val jsonRoot = remember(prettyText) { prettyText?.let(JsonOutlineNode::fromJson) }
    val showsJsonOutline = showsJsonOutline(localPretty, prettyText, jsonRoot)
    val showInlineActionsInJsonOutline =
        showInlineActionsInJsonOutline(showsJsonOutline, hasToggle, hasCopy)
    val showJsonParseFailureHint = shouldShowJsonParseFailureHint(
        prettyText = prettyText,
        isLikelyJson = isLikelyJson,
        hasToggle = hasToggle,
    )
    return InspectorPayloadDerived(
        displayText = displayText,
        hasToggle = hasToggle,
        hasCopy = hasCopy,
        jsonRoot = jsonRoot,
        payloadKey = payloadKey,
        showsJsonOutline = showsJsonOutline,
        showInlineActionsInJsonOutline = showInlineActionsInJsonOutline,
        showJsonParseFailureHint = showJsonParseFailureHint,
    )
}

private fun displayTextFor(
    localPretty: Boolean,
    prettyText: String?,
    rawText: String,
): String {
    return if (localPretty && prettyText != null) prettyText else rawText
}

private fun hasToggle(
    showsToggle: Boolean,
    prettyText: String?,
): Boolean {
    return showsToggle && prettyText != null
}

private fun hasCopy(
    showsCopyButton: Boolean,
    displayText: String,
): Boolean {
    return showsCopyButton && displayText.isNotEmpty()
}

private fun showsJsonOutline(
    localPretty: Boolean,
    prettyText: String?,
    jsonRoot: JsonOutlineNode?,
): Boolean {
    return localPretty && prettyText != null && jsonRoot != null
}

private fun showInlineActionsInJsonOutline(
    showsJsonOutline: Boolean,
    hasToggle: Boolean,
    hasCopy: Boolean,
): Boolean {
    return showsJsonOutline && (hasToggle || hasCopy)
}

private fun shouldShowJsonParseFailureHint(
    prettyText: String?,
    isLikelyJson: Boolean,
    hasToggle: Boolean,
): Boolean {
    return prettyText == null && isLikelyJson && !hasToggle
}

private data class PrettyToggleState(
    val isPretty: Boolean,
    val onTogglePretty: () -> Unit,
)

@Composable
private fun rememberPrettyToggleState(
    usePrettyPrinted: Boolean,
    onPrettyPrintedChange: (Boolean) -> Unit,
): PrettyToggleState {
    var localPretty by remember { mutableStateOf(usePrettyPrinted) }
    val latestOnPrettyPrintedChange by rememberUpdatedState(onPrettyPrintedChange)

    LaunchedEffect(usePrettyPrinted) {
        if (usePrettyPrinted != localPretty) localPretty = usePrettyPrinted
    }

    LaunchedEffect(localPretty) {
        if (localPretty != usePrettyPrinted) latestOnPrettyPrintedChange(localPretty)
    }

    return PrettyToggleState(
        isPretty = localPretty,
        onTogglePretty = { localPretty = !localPretty },
    )
}

private data class CopyFeedback(
    val didCopy: Boolean,
    val onCopy: () -> Unit,
)

@Composable
private fun rememberCopyFeedback(
    displayText: String,
    copyKey: Int,
): CopyFeedback {
    var copyToken by remember(copyKey) { mutableIntStateOf(0) }
    val didCopy = copyToken != 0
    LaunchedEffect(copyToken, copyKey) {
        if (copyToken == 0) return@LaunchedEffect
        val activeToken = copyToken
        delay(1_000)
        if (copyToken == activeToken) copyToken = 0
    }
    val onCopy = {
        NetworkInspectorCopyExporter.copyText(displayText)
        copyToken += 1
    }
    return CopyFeedback(didCopy = didCopy, onCopy = onCopy)
}

@Composable
private fun JsonParseFailureHint(show: Boolean) {
    if (!show) return
    Text(
        "Unable to pretty print (invalid or truncated JSON)",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

private data class InspectorPayloadBodyState(
    val displayText: String,
    val prettyText: String?,
    val jsonRoot: JsonOutlineNode?,
    val showsJsonOutline: Boolean,
    val showInlineActionsInJsonOutline: Boolean,
    val hasToggle: Boolean,
    val hasCopy: Boolean,
    val localPretty: Boolean,
    val didCopy: Boolean,
    val prettyInitiallyExpanded: Boolean,
    val payloadKey: Int,
    val jsonOutlineState: JsonOutlineExpansionState?,
)

private data class InspectorPayloadBodyActions(
    val onTogglePretty: () -> Unit,
    val onCopy: () -> Unit,
)

@Composable
private fun InspectorPayloadBody(
    state: InspectorPayloadBodyState,
    actions: InspectorPayloadBodyActions,
) {
    if (state.showsJsonOutline) {
        JsonOutlineView(
            root = state.jsonRoot!!,
            initiallyExpanded = state.prettyInitiallyExpanded,
            expansionState = state.jsonOutlineState,
            payloadKey = state.payloadKey,
            rootTrailingContent = inlineJsonOutlineActions(
                enabled = state.showInlineActionsInJsonOutline,
                hasToggle = state.hasToggle,
                hasCopy = state.hasCopy,
                localPretty = state.localPretty,
                didCopy = state.didCopy,
                onTogglePretty = actions.onTogglePretty,
                onCopy = actions.onCopy,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
        return
    }

    val text = if (state.localPretty && state.prettyText != null) {
        state.prettyText
    } else {
        state.displayText
    }
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        fontFamily = SnapOMono,
    )
}

@Composable
private fun inlineJsonOutlineActions(
    enabled: Boolean,
    hasToggle: Boolean,
    hasCopy: Boolean,
    localPretty: Boolean,
    didCopy: Boolean,
    onTogglePretty: () -> Unit,
    onCopy: () -> Unit,
): (@Composable RowScope.(JsonOutlineNode) -> Unit)? {
    if (!enabled) return null
    return { _ ->
        Row(
            horizontalArrangement = Arrangement.spacedBy(Spacings.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (hasToggle) {
                InspectorInlineTextToggle(
                    label = if (localPretty) "PRETTY" else "RAW",
                    onClick = onTogglePretty,
                )
            }
            if (hasCopy) {
                InspectorInlineCopyButton(
                    isCopied = didCopy,
                    onCopy = onCopy,
                )
            }
        }
    }
}

@Composable
private fun ControlsRow(
    hasToggle: Boolean,
    prettyChecked: Boolean,
    onPrettyToggle: () -> Unit,
    showsCopyButton: Boolean,
    didCopy: Boolean,
    onCopy: () -> Unit,
) {
    if (!hasToggle && !showsCopyButton) return

    Row(
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(Spacings.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (hasToggle) {
                InspectorInlineTextToggle(
                    label = if (prettyChecked) "PRETTY" else "RAW",
                    onClick = onPrettyToggle,
                )
            }
            if (showsCopyButton) {
                InspectorInlineCopyButton(
                    isCopied = didCopy,
                    onCopy = onCopy,
                )
            }
        }
    }
}

@Composable
internal fun InspectorInlineIconButton(
    icon: DrawableResource,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
) {
    // Compact desktop actions: icon-only, with subtle hover/pressed affordances.
    val interactionSource = remember { MutableInteractionSource() }
    val hovered by interactionSource.collectIsHoveredAsState()
    val pressed by interactionSource.collectIsPressedAsState()
    val bg = when {
        pressed && enabled -> MaterialTheme.colorScheme.surfaceContainerHigh
        hovered && enabled -> MaterialTheme.colorScheme.surfaceContainerLow
        else -> Color.Transparent
    }
    val iconTint = tint.copy(alpha = if (enabled) 1f else 0.4f)

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .clip(MaterialTheme.shapes.extraSmall)
            .hoverable(interactionSource)
            .background(bg)
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(Spacings.xs),
    ) {
        Icon(
            painter = painterResource(icon),
            contentDescription = contentDescription,
            tint = iconTint,
            modifier = Modifier.size(16.dp),
        )
    }
}

@Composable
internal fun InspectorInlineTextToggle(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    // Compact desktop actions: text-only, with subtle hover/pressed affordances.
    val interactionSource = remember { MutableInteractionSource() }
    val hovered by interactionSource.collectIsHoveredAsState()
    val pressed by interactionSource.collectIsPressedAsState()
    val bg = when {
        pressed && enabled -> MaterialTheme.colorScheme.surfaceContainerHigh
        hovered && enabled -> MaterialTheme.colorScheme.surfaceContainerLow
        else -> Color.Transparent
    }
    val tint = MaterialTheme.colorScheme.onSurfaceVariant
        .copy(alpha = if (enabled) 1f else 0.4f)

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .clip(MaterialTheme.shapes.extraSmall)
            .hoverable(interactionSource)
            .background(bg)
            .clickable(
                enabled = enabled,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = Spacings.sm, vertical = Spacings.xxs),
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmallEmphasized,
            color = tint,
        )
    }
}

@Composable
internal fun InspectorInlineCopyButton(
    isCopied: Boolean,
    onCopy: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val icon = if (isCopied) Res.drawable.check_24px else Res.drawable.content_copy_24px
    val description = if (isCopied) "Copied" else "Copy"
    InspectorInlineIconButton(
        icon = icon,
        contentDescription = description,
        onClick = onCopy,
        enabled = enabled,
        modifier = modifier,
    )
}

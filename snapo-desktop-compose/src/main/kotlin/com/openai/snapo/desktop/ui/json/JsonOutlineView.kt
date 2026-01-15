package com.openai.snapo.desktop.ui.json

import androidx.compose.foundation.ContextMenuArea
import androidx.compose.foundation.ContextMenuItem
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openai.snapo.desktop.inspector.NetworkInspectorCopyExporter
import com.openai.snapo.desktop.ui.TriangleIndicator
import com.openai.snapo.desktop.ui.theme.SnapOAccents
import com.openai.snapo.desktop.ui.theme.SnapOMono
import com.openai.snapo.desktop.ui.theme.Spacings

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun JsonOutlineView(
    root: JsonOutlineNode,
    modifier: Modifier = Modifier,
    initiallyExpanded: Boolean = true,
    rootTrailingContent: (@Composable RowScope.(JsonOutlineNode) -> Unit)? = null,
    expansionState: JsonOutlineExpansionState? = null,
    payloadKey: Int? = null,
) {
    val localState = remember(root.id) { JsonOutlineExpansionState(initiallyExpanded) }
    val state = expansionState ?: localState
    val effectivePayloadKey = payloadKey ?: root.hashCode()

    LaunchedEffect(effectivePayloadKey, root.id) {
        state.sync(payloadKey = effectivePayloadKey, rootId = root.id)
    }

    val rows = remember(root, state.expandedNodes) {
        buildList {
            appendNodeRows(this, node = root, indent = 0, expandedNodes = state.expandedNodes)
        }
    }

    SelectionContainer {
        Column(
            verticalArrangement = Arrangement.spacedBy(Spacings.xxs),
            modifier = modifier
                .fillMaxWidth()
                .background(Color.Transparent),
        ) {
            for (row in rows) {
                when (row) {
                    is JsonOutlineRow.Node -> JsonNodeRow(
                        node = row.node,
                        indent = row.indent,
                        expandedNodes = state.expandedNodes,
                        expandedStrings = state.expandedStrings,
                        onToggleExpand = { id ->
                            val current = state.expandedNodes
                            state.expandedNodes =
                                if (current.contains(id)) current - id else current + id
                        },
                        onToggleStringExpand = { id ->
                            val current = state.expandedStrings
                            state.expandedStrings =
                                if (current.contains(id)) current - id else current + id
                        },
                        onExpandAll = { node ->
                            state.expandedNodes =
                                state.expandedNodes + node.collectExpandableIds(includeSelf = true)
                        },
                        onCollapseChildren = { node ->
                            state.expandedNodes =
                                state.expandedNodes - node.collectExpandableIds(includeSelf = false)
                            state.expandedStrings =
                                state.expandedStrings - node.collectStringNodeIds(includeSelf = false)
                        },
                        trailingContent = if (row.node.id == root.id) rootTrailingContent else null,
                    )

                    is JsonOutlineRow.Closing -> JsonClosingRow(
                        indent = row.indent,
                        symbol = row.symbol,
                    )
                }
            }
        }
    }
}

private sealed interface JsonOutlineRow {
    val key: String

    data class Node(val node: JsonOutlineNode, val indent: Int) : JsonOutlineRow {
        override val key: String = "node:${node.id}"
    }

    data class Closing(val parentId: String, val indent: Int, val symbol: String) : JsonOutlineRow {
        override val key: String = "close:$parentId:$indent:$symbol"
    }
}

private fun appendNodeRows(
    out: MutableList<JsonOutlineRow>,
    node: JsonOutlineNode,
    indent: Int,
    expandedNodes: Set<String>,
) {
    out += JsonOutlineRow.Node(node, indent)

    val expanded = expandedNodes.contains(node.id)
    when (val v = node.value) {
        is JsonOutlineNode.Value.Obj -> {
            if (v.children.isNotEmpty() && expanded) {
                v.children.forEach { child ->
                    appendNodeRows(
                        out,
                        node = child,
                        indent = indent + 1,
                        expandedNodes = expandedNodes
                    )
                }
                out += JsonOutlineRow.Closing(parentId = node.id, indent = indent, symbol = "}")
            }
        }

        is JsonOutlineNode.Value.Arr -> {
            if (v.children.isNotEmpty() && expanded) {
                v.children.forEach { child ->
                    appendNodeRows(
                        out,
                        node = child,
                        indent = indent + 1,
                        expandedNodes = expandedNodes
                    )
                }
                out += JsonOutlineRow.Closing(parentId = node.id, indent = indent, symbol = "]")
            }
        }

        else -> Unit
    }
}

@Composable
private fun JsonClosingRow(indent: Int, symbol: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = Spacings.lg * indent),
    ) {
        TriangleIndicator(visible = false, expanded = false)
        Text(
            text = symbol,
            fontFamily = SnapOMono,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun JsonNodeRow(
    node: JsonOutlineNode,
    indent: Int,
    expandedNodes: Set<String>,
    expandedStrings: Set<String>,
    onToggleExpand: (String) -> Unit,
    onToggleStringExpand: (String) -> Unit,
    onExpandAll: (JsonOutlineNode) -> Unit,
    onCollapseChildren: (JsonOutlineNode) -> Unit,
    trailingContent: (@Composable RowScope.(JsonOutlineNode) -> Unit)?,
) {
    val expanded = expandedNodes.contains(node.id)
    val lineExpanded = when (node.value) {
        is JsonOutlineNode.Value.Str -> expandedStrings.contains(node.id)
        else -> expanded
    }

    val latestOnExpandAll by rememberUpdatedState(onExpandAll)
    val latestOnCollapseChildren by rememberUpdatedState(onCollapseChildren)
    val expandableIds = remember(node) { node.collectExpandableIds(includeSelf = true) }
    val showExpandAll = expandableIds.any { it !in expandedNodes }
    val menuItems = remember(node, showExpandAll, expanded) {
        buildContextMenuItems(
            node = node,
            showExpandAll = showExpandAll,
            isExpanded = expanded,
            onExpandAll = { latestOnExpandAll(it) },
            onCollapseChildren = { latestOnCollapseChildren(it) },
        )
    }

    ContextMenuArea(items = { menuItems }) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = Spacings.lg * indent),
        ) {
            JsonNodeRowLine(
                node = node,
                expanded = lineExpanded,
                onToggleExpand = onToggleExpand,
                trailingContent = trailingContent,
            )
            DisableSelection {
                JsonStringExpander(
                    node = node,
                    expandedStrings = expandedStrings,
                    onToggleStringExpand = onToggleStringExpand,
                )
            }
        }
    }
}

private fun buildContextMenuItems(
    node: JsonOutlineNode,
    showExpandAll: Boolean,
    isExpanded: Boolean,
    onExpandAll: (JsonOutlineNode) -> Unit,
    onCollapseChildren: (JsonOutlineNode) -> Unit,
): List<ContextMenuItem> {
    val copy = node.copyValueText(prettyPrinted = true)
    val hasCollapsibleChildren = node.collectExpandableIds(includeSelf = false).isNotEmpty()
    val items = buildList {
        if (copy != null) {
            add(ContextMenuItem("Copy Value") { NetworkInspectorCopyExporter.copyText(copy) })
        }
        if (node.isExpandable) {
            if (copy != null) {
                add(ContextMenuItem("", onClick = {}))
            }
            if (showExpandAll) {
                add(ContextMenuItem("Expand All") { onExpandAll(node) })
            }
            if (isExpanded && hasCollapsibleChildren) {
                add(ContextMenuItem("Collapse Children") { onCollapseChildren(node) })
            }
        }
    }
    return items.filter { it.label.isNotEmpty() }
}

@Composable
private fun JsonNodeRowLine(
    node: JsonOutlineNode,
    expanded: Boolean,
    onToggleExpand: (String) -> Unit,
    trailingContent: (@Composable RowScope.(JsonOutlineNode) -> Unit)?,
) {
    val accents = SnapOAccents.current()
    val palette = remember(accents) {
        JsonLinePalette(
            key = accents.jsonKey,
            numberBool = accents.jsonNumber,
            string = accents.jsonString,
            nullColor = accents.jsonNull,
        )
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            contentAlignment = Alignment.CenterStart,
            modifier = Modifier
                .weight(1f)
                .padding(vertical = 1.dp),
        ) {
            TriangleIndicator(
                visible = node.isExpandable,
                expanded = expanded,
                onClick = { if (node.isExpandable) onToggleExpand(node.id) },
            )
            val forceSingleLine = (node.isExpandable && !expanded) || trailingContent != null
            Text(
                text = buildLine(node = node, expanded = expanded, palette = palette),
                style = MaterialTheme.typography.bodySmall.copy(textIndent = TextIndent(4.sp, 4.sp)),
                fontFamily = SnapOMono,
                maxLines = if (forceSingleLine) 1 else Int.MAX_VALUE,
                overflow = if (forceSingleLine) TextOverflow.Ellipsis else TextOverflow.Clip,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = Spacings.xl),
            )
        }
        if (trailingContent != null) {
            DisableSelection {
                Spacer(Modifier.width(Spacings.md))
                trailingContent(node)
            }
        }
    }
}

@Composable
private fun JsonStringExpander(
    node: JsonOutlineNode,
    expandedStrings: Set<String>,
    onToggleStringExpand: (String) -> Unit,
) {
    val value = (node.value as? JsonOutlineNode.Value.Str)?.value ?: return
    val lines = value.split("\n")
    val isCollapsible = lines.size > 20
    if (!isCollapsible) return

    val isExpanded = expandedStrings.contains(node.id)
    val interactionSource = remember { MutableInteractionSource() }
    val hovered by interactionSource.collectIsHoveredAsState()
    val pressed by interactionSource.collectIsPressedAsState()
    val contentColor = MaterialTheme.colorScheme.onSurface.copy(
        alpha = if (pressed || hovered) 1f else 0.72f,
    )
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth(),
    ) {
        TriangleIndicator(visible = false, expanded = false)
        Text(
            text = if (isExpanded) "See less" else "See more",
            color = contentColor,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier
                .hoverable(interactionSource)
                .clickable(
                    interactionSource = interactionSource,
                    indication = null,
                    role = Role.Button,
                    onClick = { onToggleStringExpand(node.id) },
                ),
        )
    }
}

private fun buildLine(
    node: JsonOutlineNode,
    expanded: Boolean,
    palette: JsonLinePalette,
): AnnotatedString {
    return buildAnnotatedString {
        appendKey(node, palette)
        appendValue(node, expanded, palette)
    }
}

private data class JsonLinePalette(
    val key: Color,
    val numberBool: Color,
    val string: Color,
    val nullColor: Color,
)

private fun AnnotatedString.Builder.appendKey(
    node: JsonOutlineNode,
    palette: JsonLinePalette,
) {
    val key = node.key ?: return
    withStyle(SpanStyle(color = palette.key)) {
        append("$key: ")
    }
}

private fun AnnotatedString.Builder.appendValue(
    node: JsonOutlineNode,
    expanded: Boolean,
    palette: JsonLinePalette,
) {
    when (val v = node.value) {
        is JsonOutlineNode.Value.Obj -> appendObjectValue(node, v, expanded)
        is JsonOutlineNode.Value.Arr -> appendArrayValue(node, v, expanded)
        is JsonOutlineNode.Value.Str -> appendStringValue(v, expanded, palette)
        is JsonOutlineNode.Value.Num -> appendNumberValue(v, palette)
        is JsonOutlineNode.Value.Bool -> appendBooleanValue(v, palette)
        JsonOutlineNode.Value.Null -> appendNullValue(palette)
    }
}

private fun AnnotatedString.Builder.appendObjectValue(
    node: JsonOutlineNode,
    value: JsonOutlineNode.Value.Obj,
    expanded: Boolean,
) {
    if (value.children.isEmpty()) {
        append(node.inlineValueDescription(120))
    } else if (expanded) {
        append("{")
    } else {
        append(node.inlineValueDescription(120))
    }
}

private fun AnnotatedString.Builder.appendArrayValue(
    node: JsonOutlineNode,
    value: JsonOutlineNode.Value.Arr,
    expanded: Boolean,
) {
    if (value.children.isEmpty()) {
        append(node.inlineValueDescription(120))
    } else if (expanded) {
        append("[")
    } else {
        append(node.inlineValueDescription(120))
    }
}

private fun AnnotatedString.Builder.appendStringValue(
    value: JsonOutlineNode.Value.Str,
    expanded: Boolean,
    palette: JsonLinePalette,
) {
    val display = trimmedStringPreview(value.value, expanded)
    withStyle(SpanStyle(color = palette.string)) {
        append("\"$display\"")
    }
}

private fun trimmedStringPreview(value: String, expanded: Boolean): String {
    val lines = value.split("\n")
    return if (lines.size > 20 && !expanded) {
        lines.take(20).joinToString("\n") + "\n..."
    } else {
        value
    }
}

private fun AnnotatedString.Builder.appendNumberValue(
    value: JsonOutlineNode.Value.Num,
    palette: JsonLinePalette,
) {
    withStyle(SpanStyle(color = palette.numberBool)) { append(value.value) }
}

private fun AnnotatedString.Builder.appendBooleanValue(
    value: JsonOutlineNode.Value.Bool,
    palette: JsonLinePalette,
) {
    withStyle(SpanStyle(color = palette.numberBool)) {
        append(if (value.value) "true" else "false")
    }
}

private fun AnnotatedString.Builder.appendNullValue(
    palette: JsonLinePalette,
) {
    withStyle(SpanStyle(color = palette.nullColor)) { append("null") }
}

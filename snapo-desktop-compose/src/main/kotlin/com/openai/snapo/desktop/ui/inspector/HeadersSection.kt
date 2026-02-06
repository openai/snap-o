@file:OptIn(ExperimentalMaterial3ExpressiveApi::class)

package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.NativeClipboard
import androidx.compose.ui.platform.asAwtTransferable
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import com.openai.snapo.desktop.inspector.Header
import com.openai.snapo.desktop.ui.TriangleIndicator
import com.openai.snapo.desktop.ui.theme.Spacings
import java.awt.datatransfer.ClipboardOwner
import java.awt.datatransfer.DataFlavor
import java.awt.datatransfer.Transferable
import java.awt.datatransfer.UnsupportedFlavorException
import java.io.IOException
import kotlin.math.max
import java.awt.datatransfer.Clipboard as AwtClipboard

@Composable
internal fun HeadersSectionHeader(
    title: String,
    isExpanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
) {
    DisableSelection {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clickable(interactionSource = null, indication = null) {
                    onExpandedChange(!isExpanded)
                }
                .padding(vertical = Spacings.xs),
        ) {
            TriangleIndicator(expanded = isExpanded)
            Spacer(modifier = Modifier.width(Spacings.xxs))
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmallEmphasized,
            )
        }
    }
}

@Composable
internal fun HeadersSectionBody(
    headers: List<Header>,
    modifier: Modifier = Modifier,
) {
    if (headers.isEmpty()) {
        Text(
            text = "None",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = modifier,
        )
        return
    }

    val clipboard = LocalClipboard.current
    val formattingClipboard = remember(clipboard) {
        HeadersClipboard(clipboard)
    }
    val nameStyle = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold)
    val valueStyle = MaterialTheme.typography.bodySmall
    val nameIndent = rememberHeaderIndent(HeaderNamePrefix, nameStyle)
    val valueIndent = rememberHeaderIndent(HeaderValuePrefix, valueStyle)
    CompositionLocalProvider(LocalClipboard provides formattingClipboard) {
        SelectionContainer {
            HeaderGridLayout(
                rowGap = Spacings.sm,
                modifier = modifier.fillMaxWidth(),
            ) {
                headers.forEach { header ->
                    HeaderNameCell(
                        name = header.name,
                        textStyle = nameStyle,
                        textIndent = nameIndent,
                    )
                    HeaderValueCell(
                        value = header.value,
                        textStyle = valueStyle,
                        textIndent = valueIndent,
                    )
                }
            }
        }
    }
}

@Composable
private fun HeaderNameCell(
    name: String,
    textStyle: TextStyle,
    textIndent: TextIndent,
) {
    Text(
        text = "$HeaderNamePrefix$name:",
        // Keep the same metrics as the value cell. With SelectionContainer, tiny per-cell y offsets
        // can cause selection/copy ordering to feel wrong.
        style = textStyle.copy(textIndent = textIndent),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun HeaderValueCell(
    value: String,
    textStyle: TextStyle,
    textIndent: TextIndent,
) {
    Text(
        text = "$HeaderValuePrefix$value",
        style = textStyle.copy(textIndent = textIndent),
        color = MaterialTheme.colorScheme.onSurface,
    )
}

private const val FigureSpace = "\u2007"
private const val NonBreakingSpace = "\u00A0"
private const val HeaderNamePrefix = FigureSpace
private const val HeaderValuePrefix = FigureSpace + FigureSpace

@Composable
private fun rememberHeaderIndent(prefix: String, textStyle: TextStyle): TextIndent {
    val density = LocalDensity.current
    val layoutDirection = LocalLayoutDirection.current
    val fontFamilyResolver = LocalFontFamilyResolver.current
    val textMeasurer = remember(density, layoutDirection, fontFamilyResolver) {
        TextMeasurer(fontFamilyResolver, density, layoutDirection)
    }
    val indent = remember(prefix, textStyle, textMeasurer) {
        val result = textMeasurer.measure(
            text = AnnotatedString(prefix),
            style = textStyle,
        )
        with(density) { result.size.width.toSp() }
    }
    return remember(indent) { TextIndent(firstLine = 0.sp, restLine = indent) }
}

@Composable
private fun HeaderGridLayout(
    rowGap: Dp,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Layout(
        content = content,
        modifier = modifier,
    ) { measurables, constraints ->
        require(measurables.size % 2 == 0) {
            "HeaderGridLayout requires an even number of children: name/value pairs."
        }
        val measure = measureHeaderGrid(
            measurables = measurables,
            constraints = constraints,
            rowGap = rowGap,
        )

        val width = constraints.maxWidth
        val height = measure.totalHeight.coerceIn(constraints.minHeight, constraints.maxHeight)

        layout(width, height) {
            var y = 0
            val valueX = measure.maxNameWidth

            for (i in 0 until measure.rowCount) {
                measure.namePlaceables[i].placeRelative(x = 0, y = y)
                measure.valuePlaceables[i].placeRelative(x = valueX, y = y)
                y += measure.rowHeights[i] + measure.rowGapPx
            }
        }
    }
}

private data class HeaderGridMeasure(
    val rowCount: Int,
    val rowGapPx: Int,
    val maxNameWidth: Int,
    val totalHeight: Int,
    val namePlaceables: List<Placeable>,
    val valuePlaceables: List<Placeable>,
    val rowHeights: IntArray,
)

private fun MeasureScope.measureHeaderGrid(
    measurables: List<Measurable>,
    constraints: Constraints,
    rowGap: Dp,
): HeaderGridMeasure {
    val rowGapPx = rowGap.roundToPx()
    val rowCount = measurables.size / 2

    val maxNameWidth = maxNameIntrinsicWidth(
        measurables = measurables,
        rowCount = rowCount,
        maxHeight = constraints.maxHeight,
    ).coerceAtMost(constraints.maxWidth.coerceAtLeast(0))
    val nameMeasure = measureNameColumn(
        measurables = measurables,
        constraints = constraints,
        rowCount = rowCount,
        columnWidth = maxNameWidth,
    )
    val valueMeasure = measureValueColumn(
        measurables = measurables,
        constraints = constraints,
        rowCount = rowCount,
        maxNameWidth = nameMeasure.columnWidth,
    )
    val rowHeights = computeRowHeights(
        rowCount = rowCount,
        namePlaceables = nameMeasure.placeables,
        valuePlaceables = valueMeasure,
    )
    val totalHeight = rowHeights.sum() + rowGapPx * max(0, rowCount - 1)

    return HeaderGridMeasure(
        rowCount = rowCount,
        rowGapPx = rowGapPx,
        maxNameWidth = nameMeasure.columnWidth,
        totalHeight = totalHeight,
        namePlaceables = nameMeasure.placeables,
        valuePlaceables = valueMeasure,
        rowHeights = rowHeights,
    )
}

private data class NameColumnMeasure(
    val placeables: List<Placeable>,
    val columnWidth: Int,
)

private fun maxNameIntrinsicWidth(
    measurables: List<Measurable>,
    rowCount: Int,
    maxHeight: Int,
): Int {
    var maxWidth = 0
    for (i in 0 until rowCount) {
        val measurable = measurables[i * 2]
        maxWidth = max(maxWidth, measurable.maxIntrinsicWidth(maxHeight))
    }
    return maxWidth
}

private fun measureNameColumn(
    measurables: List<Measurable>,
    constraints: Constraints,
    rowCount: Int,
    columnWidth: Int,
): NameColumnMeasure {
    val nameConstraints = constraints.copy(
        minWidth = columnWidth,
        minHeight = 0,
        maxWidth = columnWidth,
    )
    val namePlaceables = ArrayList<Placeable>(rowCount)
    for (i in 0 until rowCount) {
        val measurable = measurables[i * 2]
        val placeable = measurable.measure(nameConstraints)
        namePlaceables += placeable
    }
    return NameColumnMeasure(placeables = namePlaceables, columnWidth = columnWidth)
}

private fun measureValueColumn(
    measurables: List<Measurable>,
    constraints: Constraints,
    rowCount: Int,
    maxNameWidth: Int,
): List<Placeable> {
    val valueMaxWidth = (constraints.maxWidth - maxNameWidth).coerceAtLeast(0)
    val valueConstraints = Constraints(
        minWidth = valueMaxWidth,
        maxWidth = valueMaxWidth,
        minHeight = 0,
        maxHeight = constraints.maxHeight,
    )
    val valuePlaceables = ArrayList<Placeable>(rowCount)
    for (i in 0 until rowCount) {
        val measurable = measurables[i * 2 + 1]
        valuePlaceables += measurable.measure(valueConstraints)
    }
    return valuePlaceables
}

private fun computeRowHeights(
    rowCount: Int,
    namePlaceables: List<Placeable>,
    valuePlaceables: List<Placeable>,
): IntArray {
    val rowHeights = IntArray(rowCount)
    for (i in 0 until rowCount) {
        val name = namePlaceables[i]
        val value = valuePlaceables[i]
        rowHeights[i] = max(name.height, value.height)
    }
    return rowHeights
}

/**
 * Compose selection concatenates each selectable with '\n'. Our grid is built from two Text nodes per row
 * (name + value), so copying would otherwise produce:
 *   Name:\nValue\nName2:\nValue2
 *
 * Intercept clipboard writes within this section and reformat into "Name: Value" per line.
 */
private class HeadersClipboard(
    private val delegate: Clipboard,
) : Clipboard {
    override val nativeClipboard: NativeClipboard
        get() = delegate.nativeClipboard

    override suspend fun getClipEntry(): ClipEntry? = delegate.getClipEntry()

    override suspend fun setClipEntry(clipEntry: ClipEntry?) {
        delegate.setClipEntry(maybeFormatHeaders(clipEntry))
    }

    @OptIn(ExperimentalComposeUiApi::class)
    private fun maybeFormatHeaders(input: ClipEntry?): ClipEntry? {
        if (input == null) return null
        val transferable = input.asAwtTransferable ?: return input
        if (!transferable.isDataFlavorSupported(DataFlavor.stringFlavor)) return input

        val raw =
            try {
                transferable.getTransferData(DataFlavor.stringFlavor) as? String
            } catch (_: UnsupportedFlavorException) {
                null
            } catch (_: IOException) {
                null
            }
                ?: return input

        val formatted = formatHeaderGridSelectionText(raw) ?: return input
        if (formatted == raw) return input

        return ClipEntry(AnnotatedStringTransferable(AnnotatedString(formatted)))
    }
}

/**
 * If the copied text looks like alternating grid cells ("name:\nvalue\nname2:\nvalue2..."), merge
 * each row into a single line ("name: value").
 *
 * Return null to keep the original.
 */
private fun formatHeaderGridSelectionText(raw: String): String? {
    val lines = raw.split('\n')
    if (lines.size < 2 || lines.size % 2 != 0) return null

    val nameLines = lines.filterIndexed { index, _ -> index % 2 == 0 }
        .map(::stripHeaderIndent)
    val valueLines = lines.filterIndexed { index, _ -> index % 2 == 1 }
        .map(::stripHeaderIndent)

    val nameLooksRight = nameLines.all { it.trimEnd().endsWith(':') }
    val valueLooksRight = valueLines.none { it.trimEnd().endsWith(':') }
    if (!nameLooksRight || !valueLooksRight) return null

    return buildString {
        for (i in nameLines.indices) {
            val name = nameLines[i].trimEnd()
            val value = valueLines[i].trimStart()
            append(name)
            if (value.isNotEmpty()) {
                append(' ')
                append(value)
            }
            if (i != nameLines.lastIndex) append('\n')
        }
    }
}

private fun stripHeaderIndent(value: String): String {
    var start = 0
    while (start < value.length) {
        val ch = value[start]
        if (ch == FigureSpace[0] || ch == NonBreakingSpace[0]) {
            start += 1
        } else {
            break
        }
    }
    return if (start == 0) value else value.substring(start)
}

@OptIn(ExperimentalComposeUiApi::class)
private class AnnotatedStringTransferable(
    private val data: AnnotatedString,
) : Transferable, ClipboardOwner {
    override fun getTransferDataFlavors(): Array<DataFlavor?> = supportedFlavors

    override fun isDataFlavorSupported(flavor: DataFlavor): Boolean = flavor in supportedFlavors

    override fun getTransferData(flavor: DataFlavor): Any =
        when (flavor) {
            annotatedStringFlavor -> data
            DataFlavor.stringFlavor -> data.text
            else -> throw UnsupportedFlavorException(flavor)
        }

    override fun lostOwnership(
        clipboard: AwtClipboard?,
        contents: Transferable?,
    ) = Unit

    companion object {
        private val annotatedStringFlavor: DataFlavor =
            DataFlavor(AnnotatedString::class.java, "AnnotatedString")
        private val supportedFlavors = arrayOf(annotatedStringFlavor, DataFlavor.stringFlavor)
    }
}

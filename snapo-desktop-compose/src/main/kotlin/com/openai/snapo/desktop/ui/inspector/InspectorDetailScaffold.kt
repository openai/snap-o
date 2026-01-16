package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.VerticalScrollbar
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollbarAdapter
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.openai.snapo.desktop.ui.theme.Spacings

internal val InspectorDetailContentPadding = PaddingValues(
    start = Spacings.xl,
    top = Spacings.xxxl,
    end = Spacings.xxxl,
    bottom = Spacings.xxxl,
)

@Composable
fun InspectorDetailScaffold(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = InspectorDetailContentPadding,
    selectionEnabled: Boolean = true,
    content: LazyListScope.() -> Unit,
) {
    val listState = rememberLazyListState()
    Box(modifier = modifier.fillMaxSize()) {
        val list = @Composable {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                state = listState,
                contentPadding = contentPadding,
                content = content,
            )
        }
        if (selectionEnabled) {
            SelectionContainer {
                list()
            }
        } else {
            list()
        }
        VerticalScrollbar(
            adapter = rememberScrollbarAdapter(listState),
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .fillMaxHeight(),
        )
    }
}

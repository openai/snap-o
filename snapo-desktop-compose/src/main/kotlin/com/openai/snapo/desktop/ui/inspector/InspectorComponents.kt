package com.openai.snapo.desktop.ui.inspector

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.openai.snapo.desktop.ui.theme.Spacings

@Composable
fun InspectorCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                shape = MaterialTheme.shapes.extraSmall,
            )
            .padding(horizontal = Spacings.mdPlus, vertical = Spacings.md),
    ) {
        content()
    }
}

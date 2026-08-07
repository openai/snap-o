package com.openai.snapo.demo.tweaks

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openai.snapo.tweaks.tweak

private const val SharedHighlightKey = "shared_highlight"

@Composable
internal fun SharedScreen(modifier: Modifier) {
    val dividerColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
    val context = LocalContext.current
    val settings = remember(context) {
        context.getSharedPreferences("snapo_tweak_demo", Context.MODE_PRIVATE)
    }

    LazyColumn(
        modifier = modifier,
        contentPadding = PaddingValues(horizontal = 28.dp, vertical = 26.dp),
    ) {
        item {
            Column(
                modifier = Modifier.padding(bottom = 18.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = "One property, many rows",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    text = "Every row shares the same corner radius and highlight setting.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                )
            }
        }
        items(count = 24) { index ->
            SharedPropertyRow(index, settings)
            HorizontalDivider(color = dividerColor)
        }
    }
}

@Composable
private fun SharedPropertyRow(index: Int, settings: SharedPreferences) {
    val cornerRadius by tweak(12, "Shared/Corner radius", 0..24, step = 1)
    val isHighlighted by settings.tweak(
        key = SharedHighlightKey,
        default = true,
        name = "Shared/Highlight",
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(width = 64.dp, height = 48.dp)
                .background(
                    color = MaterialTheme.colorScheme.primary.copy(
                        alpha = if (isHighlighted) 0.4f + (index % 4) * 0.15f else 0.12f,
                    ),
                    shape = RoundedCornerShape(cornerRadius.dp),
                ),
        )
        Text(
            text = "Item ${(index + 1).toString().padStart(2, '0')}",
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyLarge,
        )
        Text(
            text = "$cornerRadius dp",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
        )
    }
}

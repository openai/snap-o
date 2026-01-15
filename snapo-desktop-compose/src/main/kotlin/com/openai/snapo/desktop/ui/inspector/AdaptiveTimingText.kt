package com.openai.snapo.desktop.ui.inspector

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.openai.snapo.desktop.inspector.InspectorTiming
import com.openai.snapo.desktop.inspector.NetworkInspectorRequestStatus
import kotlinx.coroutines.delay
import java.time.Duration
import java.time.Instant

@Composable
fun AdaptiveTimingText(
    timing: InspectorTiming,
    status: NetworkInspectorRequestStatus,
    modifier: Modifier = Modifier,
) {
    var now by remember { mutableStateOf(Instant.now()) }

    LaunchedEffect(timing, status) {
        // SwiftUI version updates every second until 60s then every 60s.
        while (true) {
            now = Instant.now()
            val elapsed = Duration.between(
                timing.fallbackRange.first,
                now,
            ).seconds
            val intervalMs = if (elapsed >= 60) 60_000L else 1_000L
            delay(intervalMs)
        }
    }

    Text(
        text = timing.summary(status = status, now = now),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier,
    )
}

package com.openai.snapo.demo.tweaks

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlay
import com.openai.snapo.tweaks.overlay.SnapOTweakOverlaySettings

private val DefaultTextColor = Color(0xFF18212F)
private val DefaultBackgroundColor = Color(0xFFF7F8FA)
private val DefaultAccentColor = Color(0xFF5468FF)

private enum class DemoDestination(val label: String) {
    Overview("Overview"),
    Shared("Shared"),
}

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            TweakDemo()
        }
    }
}

@Composable
private fun TweakDemo() {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = DefaultAccentColor,
            onPrimary = Color.White,
            background = DefaultBackgroundColor,
            onBackground = DefaultTextColor,
            surface = DefaultBackgroundColor,
            onSurface = DefaultTextColor,
        ),
    ) {
        SnapOTweakOverlay {
            TweakDemoScreen()
        }
    }
}

@Composable
private fun TweakDemoScreen() {
    var isTweakableContentVisible by rememberSaveable { mutableStateOf(true) }
    var destination by rememberSaveable { mutableStateOf(DemoDestination.Overview) }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background,
        contentColor = MaterialTheme.colorScheme.onBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 28.dp)
                    .padding(top = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                DestinationTabs(
                    destination = destination,
                    onDestinationSelected = { destination = it },
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OverlayEnableSwitch()
                    TextButton(
                        onClick = {
                            isTweakableContentVisible = !isTweakableContentVisible
                        },
                    ) {
                        Text(if (isTweakableContentVisible) "Hide content" else "Show content")
                    }
                }
            }

            val contentModifier = Modifier.weight(1f)
            if (!isTweakableContentVisible) {
                Text(
                    text = "Tweakable UI is hidden.",
                    modifier = contentModifier.padding(horizontal = 28.dp, vertical = 26.dp),
                    style = MaterialTheme.typography.bodyLarge,
                )
            } else {
                when (destination) {
                    DemoDestination.Overview -> OverviewScreen(modifier = contentModifier)
                    DemoDestination.Shared -> SharedScreen(modifier = contentModifier)
                }
            }
        }
    }
}

@Composable
private fun DestinationTabs(
    destination: DemoDestination,
    onDestinationSelected: (DemoDestination) -> Unit,
) {
    PrimaryTabRow(
        selectedTabIndex = destination.ordinal,
        containerColor = Color.Transparent,
        divider = {
            HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f))
        },
    ) {
        DemoDestination.entries.forEach { tabDestination ->
            Tab(
                selected = destination == tabDestination,
                onClick = { onDestinationSelected(tabDestination) },
                text = { Text(tabDestination.label) },
            )
        }
    }
}

@Composable
private fun OverlayEnableSwitch() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "Overlay",
            style = MaterialTheme.typography.bodyLarge,
        )
        Switch(
            checked = SnapOTweakOverlaySettings.isEnabled,
            onCheckedChange = { SnapOTweakOverlaySettings.isEnabled = it },
        )
    }
}

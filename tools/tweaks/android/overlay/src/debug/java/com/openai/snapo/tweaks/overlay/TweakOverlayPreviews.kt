package com.openai.snapo.tweaks.overlay

import android.content.res.Configuration
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openai.snapo.tweaks.BezierCurve
import com.openai.snapo.tweaks.SnapOTweaks
import com.openai.snapo.tweaks.internal.TweakDescriptor
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweakType
import com.openai.snapo.tweaks.toTweakColorValue

private val duration = TweakDescriptor("Motion/Duration", TweakType.INT, 300, min = 0, max = 500, step = 25)
private val fineDuration = TweakDescriptor("Motion/Fine duration", TweakType.INT, 300, min = 0, max = 500, step = 1)
private val playback = TweakDescriptor(
    "Motion/Playback",
    TweakType.ENUM,
    "Balanced",
    options = listOf("Gentle", "Balanced", "Snappy"),
)
private val repeat = TweakDescriptor("Motion/Repeat", TweakType.BOOLEAN, true)
private val easing = TweakDescriptor("Motion/Easing", TweakType.BEZIER, BezierCurve(0.4f, 0f, 0.2f, 1f))
private val longSliderLabelSamples = listOf(
    TweakDescriptor("Toolbar height (dp)", TweakType.INT, 56, min = 32, max = 96, step = 1),
    TweakDescriptor("Maximum expanded toolbar height (dp)", TweakType.INT, 96, min = 48, max = 160, step = 1),
    TweakDescriptor(
        "Minimum distance between the toolbar button and the text field (dp)",
        TweakType.FLOAT,
        8f,
        min = 0f,
        max = 24f,
        step = 0.5f,
    ),
)
private val appearanceTweaks = listOf(
    TweakDescriptor("Accent color", TweakType.COLOR, "#5468FF".toTweakColorValue()),
    TweakDescriptor("Opacity", TweakType.FLOAT, 0.75f, min = 0f, max = 1f),
    TweakDescriptor(
        "Color mode",
        TweakType.ENUM,
        "Follow system appearance",
        options = listOf("Light", "Dark", "Follow system appearance"),
    ),
    TweakDescriptor("Caption", TweakType.STRING, "Sample"),
)
internal val allControlPreviewSamples = appearanceTweaks + longSliderLabelSamples + listOf(
    repeat,
    easing,
    duration,
    TweakDescriptor("Motion/Iterations", TweakType.INT, 3),
    TweakDescriptor("Motion/Speed multiplier", TweakType.FLOAT, 1.25f),
    TweakDescriptor("Motion/Reset duration", TweakType.ACTION, Unit),
)

@Preview(
    name = "All control types",
    group = "Tweaks overlay",
    widthDp = 432,
    showBackground = true,
    backgroundColor = 0xFFEBEDF0,
)
@Composable
internal fun AllControlsPreview() {
    OverlayPreview(
        samples = allControlPreviewSamples,
        height = 732.dp,
        onAction = { SnapOTweaks.reset(duration.name) },
    )
}

@Preview(
    name = "Slider first",
    group = "Tweaks overlay",
    widthDp = 360,
    showBackground = true,
    backgroundColor = 0xFFEBEDF0,
)
@Composable
internal fun SliderFirstPreview() {
    OverlayPreview(listOf(duration, playback, repeat, easing))
}

@Preview(
    name = "Sparse and dense slider steps",
    group = "Tweaks overlay",
    widthDp = 360,
    showBackground = true,
    backgroundColor = 0xFFEBEDF0,
)
@Composable
internal fun SliderPrecisionPreview() {
    OverlayPreview(listOf(duration, fineDuration, repeat, playback))
}

@Preview(
    name = "Long slider labels",
    group = "Tweaks overlay",
    widthDp = 432,
    showBackground = true,
    backgroundColor = 0xFFEBEDF0,
)
@Preview(
    name = "Long slider labels · narrow with large text",
    group = "Tweaks overlay",
    widthDp = 300,
    fontScale = 1.6f,
    showBackground = true,
    backgroundColor = 0xFFEBEDF0,
)
@Composable
internal fun LongSliderLabelsPreview() {
    OverlayPreview(longSliderLabelSamples, height = 240.dp)
}

@Preview(
    name = "Picker first · dark",
    group = "Tweaks overlay",
    widthDp = 360,
    uiMode = Configuration.UI_MODE_NIGHT_YES,
    showBackground = true,
    backgroundColor = 0xFF171A20,
)
@Composable
internal fun PickerFirstPreview() {
    OverlayPreview(listOf(playback, easing, duration, repeat))
}

@Preview(
    name = "Mixed fields · narrow",
    group = "Tweaks overlay",
    widthDp = 300,
    showBackground = true,
    backgroundColor = 0xFFEBEDF0,
)
@Composable
internal fun MixedFieldsPreview() {
    OverlayPreview(appearanceTweaks)
}

@Composable
private fun OverlayPreview(
    samples: List<TweakDescriptor>,
    height: Dp = TweakOverlayLayout.height,
    onAction: () -> Unit = {},
) {
    // Studio renders the overlay without running the app's startup provider.
    samples.forEach { sample ->
        DisposableEffect(sample, onAction) {
            if (sample.type == TweakType.ACTION) {
                val action = TweakRegistry.registerAction(sample.name, onAction)
                onDispose { action.close() }
            } else {
                TweakRegistry.register(sample)
                onDispose { TweakRegistry.unregister(sample.name) }
            }
        }
    }
    val activeTweaks by SnapOTweaks.activeTweakEntries()
    val tweaks = remember(samples, activeTweaks) {
        val entries = activeTweaks.associateBy { it.name }
        samples.mapNotNull { entries[it.name] }
    }
    TweakOverlayTheme {
        ExpandedTweakOverlay(
            tweaks = tweaks,
            height = height,
            onMinimize = {},
            onDrag = {},
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        )
    }
}

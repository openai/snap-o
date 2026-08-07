package com.openai.snapo.demo.tweaks

import android.content.Context
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openai.snapo.tweaks.TweakAction
import com.openai.snapo.tweaks.tweak
import kotlin.math.roundToInt

private enum class MotionMarkerShape(val shape: Shape) {
    Circle(CircleShape),
    RoundedSquare(RoundedCornerShape(28)),
    Square(RectangleShape),
}

@Composable
internal fun OverviewScreen(modifier: Modifier) {
    val defaultColors = MaterialTheme.colorScheme
    val textColor by tweak(defaultColors.onBackground, "Colors/Text")
    val backgroundColor by tweak(defaultColors.background, "Colors/Background")
    val accentColor by tweak(defaultColors.primary, "Colors/Accent")

    MaterialTheme(
        colorScheme = defaultColors.copy(
            primary = accentColor,
            background = backgroundColor,
            onBackground = textColor,
            surface = backgroundColor,
            onSurface = textColor,
        ),
    ) {
        Surface(
            modifier = modifier,
            color = MaterialTheme.colorScheme.background,
            contentColor = MaterialTheme.colorScheme.onBackground,
        ) {
            val dividerColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 28.dp, vertical = 26.dp),
                verticalArrangement = Arrangement.spacedBy(30.dp),
            ) {
                DemoHeader()
                HorizontalDivider(color = dividerColor)
                TypographyPreview()
                MotionSection(dividerColor)
            }
        }
    }
}

@Composable
private fun DemoHeader() {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = "Snap-O Tweaks",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = "Type, color, and motion respond instantly.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
        )
    }
}

@Composable
private fun TypographyPreview() {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            text = "Typography",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
        )
        TweakableTypographyPreview()
        TypographyDetails()
    }
}

@Composable
private fun TweakableTypographyPreview() {
    val fontSize by tweak(36, "Typography/Font size", 16..72, step = 1)
    val fontWeight by tweak(600, "Typography/Font weight", 100..900, step = 100)
    val previewText by tweak("Make it feel right.", name = "Typography/Preview text")

    Text(
        text = previewText,
        color = MaterialTheme.colorScheme.onSurface,
        fontSize = fontSize.sp,
        fontWeight = FontWeight(fontWeight),
        lineHeight = (fontSize * 1.2f).sp,
    )
}

@Composable
private fun TypographyDetails() {
    val fontSize by tweak(36, "Typography/Font size", 16..72, step = 1)
    val fontWeight by tweak(600, "Typography/Font weight", 100..900, step = 100)

    Text(
        text = "$fontSize sp · $fontWeight",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
    )
}

@Composable
private fun MotionSection(dividerColor: Color) {
    val context = LocalContext.current
    val settings = remember(context) {
        context.getSharedPreferences("snapo_tweak_demo", Context.MODE_PRIVATE)
    }
    val isVisible by settings.tweak(
        key = "motion_show",
        default = true,
        name = "Motion/Show",
    )
    if (isVisible) {
        HorizontalDivider(color = dividerColor)
        MotionPreview()
    }
}

@Composable
private fun MotionPreview() {
    var isStateB by rememberSaveable { mutableStateOf(false) }
    TweakAction("Motion/Toggle animation") { isStateB = !isStateB }
    val useSpring by tweak(true, "Motion/Use spring")

    val animationSpec: FiniteAnimationSpec<Float> = if (useSpring) {
        val stiffness by tweak(280f, "Motion/Spring stiffness", 80f..800f, step = 20f)
        val dampingRatio by tweak(0.7f, "Motion/Spring damping", 0.1f..1f, step = 0.05f)

        spring(
            dampingRatio = dampingRatio,
            stiffness = stiffness,
            visibilityThreshold = 0.001f,
        )
    } else {
        val durationMillis by tweak(400, "Motion/Duration", 100..1500, step = 50)

        tween(
            durationMillis = durationMillis,
            easing = FastOutSlowInEasing,
        )
    }
    val progress = animateFloatAsState(
        targetValue = if (isStateB) 1f else 0f,
        animationSpec = animationSpec,
        label = "Snap-O Tweaks transition",
    )

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(
            text = "Motion",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
        )
        MotionTrack(
            progress = progress,
            isStateB = isStateB,
            onToggle = { isStateB = !isStateB },
        )
        Button(onClick = { isStateB = !isStateB }) {
            Text("Tap to animate")
        }
        AnimationDetails(
            isStateB = isStateB,
        )
    }
}

@Composable
private fun MotionTrack(
    progress: State<Float>,
    isStateB: Boolean,
    onToggle: () -> Unit,
) {
    val accentColor = MaterialTheme.colorScheme.primary
    val mutedColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.55f)
    val trackColor = accentColor.copy(alpha = 0.22f)
    val trackThickness by tweak(2f, "Motion/Track thickness", 1f..8f, step = 0.5f)
    val markerShape by tweak(MotionMarkerShape.Circle, "Motion/Marker shape")

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("State A", color = if (isStateB) mutedColor else accentColor)
            Text("State B", color = if (isStateB) accentColor else mutedColor)
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(64.dp)
                .clickable(role = Role.Button, onClick = onToggle)
                .drawBehind {
                    drawLine(
                        color = trackColor,
                        start = Offset(x = 0f, y = center.y),
                        end = Offset(x = size.width, y = center.y),
                        strokeWidth = trackThickness.dp.toPx(),
                    )
                },
            contentAlignment = Alignment.CenterStart,
        ) {
            val markerSize = 40.dp

            Box(
                modifier = Modifier
                    .motionMarkerOffset(progress)
                    .size(markerSize)
                    .background(accentColor, markerShape.shape),
            )
        }
    }
}

@Composable
private fun Modifier.motionMarkerOffset(progress: State<Float>): Modifier =
    layout { measurable, constraints ->
        val marker = measurable.measure(constraints)
        val travel = (constraints.maxWidth - marker.width).coerceAtLeast(0)

        layout(marker.width, marker.height) {
            marker.placeRelative(
                x = (travel * progress.value).roundToInt(),
                y = 0,
            )
        }
    }

@Composable
private fun AnimationDetails(
    isStateB: Boolean,
) {
    val useSpring by tweak(true, "Motion/Use spring")
    val description = if (useSpring) {
        val stiffness by tweak(280f, "Motion/Spring stiffness", 80f..800f, step = 20f)
        val dampingRatio by tweak(0.7f, "Motion/Spring damping", 0.1f..1f, step = 0.05f)

        "Spring · $stiffness stiffness · $dampingRatio damping"
    } else {
        val durationMillis by tweak(400, "Motion/Duration", 100..1500, step = 50)

        "Tween · $durationMillis ms"
    }
    val selectedState = if (isStateB) "State B" else "State A"

    Text(
        text = "$description · $selectedState",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
    )
}

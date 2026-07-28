package com.openai.snapo.demo.tweaks

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openai.snapo.tweaks.tweakBoolean
import com.openai.snapo.tweaks.tweakColor
import com.openai.snapo.tweaks.tweakFloat
import com.openai.snapo.tweaks.tweakInt
import com.openai.snapo.tweaks.tweakString

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
    val textColor = tweakColor("Colors/Text", Color(0xFF18212F))
    val backgroundColor = tweakColor("Colors/Background", Color(0xFFF7F8FA))
    val accentColor = tweakColor("Colors/Accent", Color(0xFF5468FF))

    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = accentColor,
            onPrimary = Color.White,
            background = backgroundColor,
            onBackground = textColor,
            surface = backgroundColor,
            onSurface = textColor,
        ),
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = backgroundColor,
            contentColor = textColor,
        ) {
            TweakDemoContent()
        }
    }
}

@Composable
private fun TweakDemoContent() {
    val dividerColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
    val showMotion = tweakBoolean("Motion/Show", true)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 28.dp, vertical = 28.dp),
        verticalArrangement = Arrangement.spacedBy(30.dp),
    ) {
        DemoHeader()
        HorizontalDivider(color = dividerColor)
        TypographyPreview()

        if (showMotion) {
            HorizontalDivider(color = dividerColor)
            MotionPreview()
        }
    }
}

@Composable
private fun DemoHeader() {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "Snap-O Tweaks",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
        )
        Text(
            text = "Live tweaks",
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
    val fontSize = tweakInt("Typography/Font size", 36, min = 16, max = 72, step = 1)
    val fontWeight = tweakInt("Typography/Font weight", 600, min = 100, max = 900, step = 100)
    val previewText = tweakString("Typography/Preview text", "Make it feel right.")

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(
            text = "Typography",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(
            text = previewText,
            color = MaterialTheme.colorScheme.onSurface,
            fontSize = fontSize.sp,
            fontWeight = FontWeight(fontWeight),
            lineHeight = (fontSize * 1.2f).sp,
        )
        TypographyDetails()
    }
}

@Composable
private fun TypographyDetails() {
    val fontSize = tweakInt("Typography/Font size", 36, min = 16, max = 72, step = 1)
    val fontWeight = tweakInt("Typography/Font weight", 600, min = 100, max = 900, step = 100)

    Text(
        text = "$fontSize sp · $fontWeight",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
    )
}

@Composable
private fun MotionPreview() {
    var isStateB by rememberSaveable { mutableStateOf(false) }
    val duration = tweakInt("Motion/Duration", 400, min = 100, max = 1500, step = 50)
    val stiffness = tweakFloat("Motion/Spring stiffness", 280f, min = 80f, max = 800f, step = 20f)
    val damping = tweakFloat("Motion/Spring damping", 0.7f, min = 0.1f, max = 1f, step = 0.05f)
    val useSpring = tweakBoolean("Motion/Use spring", true)

    val animationSpec: FiniteAnimationSpec<Float> = if (useSpring) {
        spring(
            dampingRatio = damping,
            stiffness = stiffness,
        )
    } else {
        tween(
            durationMillis = duration,
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

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("State A", color = if (isStateB) mutedColor else accentColor)
            Text("State B", color = if (isStateB) accentColor else mutedColor)
        }
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .height(64.dp)
                .clickable(role = Role.Button, onClick = onToggle),
            contentAlignment = Alignment.CenterStart,
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(2.dp)
                    .background(accentColor.copy(alpha = 0.22f)),
            )

            val markerSize = 40.dp
            val markerTravel = (maxWidth - markerSize).coerceAtLeast(0.dp)

            Box(
                modifier = Modifier
                    .offset {
                        IntOffset(
                            x = (markerTravel * progress.value).roundToPx(),
                            y = 0,
                        )
                    }
                    .size(markerSize)
                    .background(accentColor, CircleShape),
            )
        }
    }
}

@Composable
private fun AnimationDetails(
    isStateB: Boolean,
) {
    val useSpring = tweakBoolean("Motion/Use spring", true)
    val description = if (useSpring) {
        val stiffness = tweakFloat("Motion/Spring stiffness", 280f, min = 80f, max = 800f, step = 20f)
        val damping = tweakFloat("Motion/Spring damping", 0.7f, min = 0.1f, max = 1f, step = 0.05f)

        "Spring · $stiffness stiffness · $damping damping"
    } else {
        val duration = tweakInt("Motion/Duration", 400, min = 100, max = 1500, step = 50)

        "Tween · $duration ms"
    }
    val selectedState = if (isStateB) "State B" else "State A"

    Text(
        text = "$description · $selectedState",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.65f),
    )
}

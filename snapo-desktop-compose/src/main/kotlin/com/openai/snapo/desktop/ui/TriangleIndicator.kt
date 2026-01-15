package com.openai.snapo.desktop.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import com.openai.snapo.desktop.generated.resources.Res
import com.openai.snapo.desktop.generated.resources.arrow_drop_down_24px
import com.openai.snapo.desktop.generated.resources.arrow_right_24px
import org.jetbrains.compose.resources.painterResource

@Composable
fun TriangleIndicator(
    expanded: Boolean,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    visible: Boolean = true,
) {
    // Keep width stable for alignment. We keep an (invisible) icon for non-expandable rows.
    val drawable =
        if (expanded) Res.drawable.arrow_drop_down_24px else Res.drawable.arrow_right_24px

    Icon(
        painter = painterResource(drawable),
        contentDescription = null,
        tint = MaterialTheme.colorScheme.onSurface,
        modifier = modifier
            .size(20.dp, 12.dp)
            .requiredSize(28.dp)
            .then(if (visible) Modifier else Modifier.alpha(0f))
            .let { base ->
                if (onClick != null && visible) {
                    base.clickable(
                        interactionSource = null,
                        indication = null,
                        onClick = onClick
                    )
                } else {
                    base
                }
            },
    )
}

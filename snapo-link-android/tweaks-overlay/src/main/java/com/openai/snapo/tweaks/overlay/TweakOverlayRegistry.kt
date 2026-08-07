package com.openai.snapo.tweaks.overlay

import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import com.openai.snapo.tweaks.SnapOTweakEntry
import com.openai.snapo.tweaks.SnapOTweakValue
import com.openai.snapo.tweaks.SnapOTweaks

@Composable
internal fun rememberActiveOverlayTweaks(): List<SnapOTweakEntry> {
    val sectionOrder = remember { TweakOverlaySectionOrder() }
    val tweaks by SnapOTweaks.activeTweakEntries()

    SideEffect {
        sectionOrder.observe(tweaks) { tweak ->
            tweak.name.substringBefore('/', missingDelimiterValue = "")
        }
    }

    return remember(tweaks) {
        sectionOrder.sorted(tweaks) { tweak ->
            tweak.name.substringBefore('/', missingDelimiterValue = "")
        }
    }
}

internal class TweakOverlaySectionOrder {
    private val observedSections = HashMap<String, Int>()

    fun <T> arrange(
        items: List<T>,
        section: (T) -> String,
    ): List<T> {
        observe(items, section)
        return sorted(items, section)
    }

    fun <T> observe(
        items: List<T>,
        section: (T) -> String,
    ) {
        items.forEach { item ->
            val name = section(item)
            if (name !in observedSections) {
                observedSections[name] = observedSections.size
            }
        }
    }

    fun <T> sorted(
        items: List<T>,
        section: (T) -> String,
    ): List<T> {
        val currentSections = HashMap(observedSections)
        items.forEach { item ->
            val name = section(item)
            if (name !in currentSections) {
                currentSections[name] = currentSections.size
            }
        }

        return items.sortedBy { item ->
            currentSections.getValue(section(item))
        }
    }
}

internal val SnapOTweakEntry.isChanged: Boolean
    get() = value.value !is SnapOTweakValue.Action && modified.value

package com.openai.snapo.desktop.update

import java.util.concurrent.TimeUnit
import java.util.prefs.BackingStoreException
import java.util.prefs.Preferences

// We mirror Sparkle's auto-update preference from the host macOS app so the helper app
// doesn't diverge from the user's chosen update behavior.
private const val SnapODefaultsDomain = "com.openai.snapo"
private const val SparkleAutoCheckKey = "SUEnableAutomaticChecks"
private const val DefaultsToolPath = "/usr/bin/defaults"
private const val HelperPrefsNode = "com.openai.snapo.desktop.update"
private const val PromptedForPermissionKey = "sparklePermissionPrompted"

internal sealed interface AutoCheckDecision {
    data object Enabled : AutoCheckDecision
    data object Disabled : AutoCheckDecision
    data object PromptHost : AutoCheckDecision
}

internal fun autoCheckDecision(): AutoCheckDecision {
    // Prefer the host app's persisted Sparkle preference when available.
    val preference = readSparkleAutoCheckPreference()
    if (preference != null) {
        return if (preference) AutoCheckDecision.Enabled else AutoCheckDecision.Disabled
    }
    // No persisted value yet: ask the host app to prompt once so the user can opt in/out.
    return if (markPromptedIfNeeded()) AutoCheckDecision.PromptHost else AutoCheckDecision.Disabled
}

private fun readSparkleAutoCheckPreference(): Boolean? {
    // Prefer macOS defaults (NSUserDefaults) where the host app stores Sparkle keys.
    readSparkleAutoCheckPreferenceFromDefaults()?.let { return it }
    // Fall back to Java prefs when defaults are unavailable (e.g., non-macOS or restricted envs).
    return readSparkleAutoCheckPreferenceFromJavaPrefs()
}

private fun readSparkleAutoCheckPreferenceFromDefaults(): Boolean? {
    if (!isMacOs()) return null
    return runCatching {
        // Use the system defaults tool to read the host app's preference domain.
        val process = ProcessBuilder(
            DefaultsToolPath,
            "read",
            SnapODefaultsDomain,
            SparkleAutoCheckKey,
        )
            .redirectErrorStream(true)
            .start()
        val finished = process.waitFor(1, TimeUnit.SECONDS)
        if (!finished) {
            process.destroyForcibly()
            return null
        }
        val output = process.inputStream.bufferedReader().readText().trim()
        if (process.exitValue() != 0) return null
        parseBooleanPreference(output)
    }.getOrNull()
}

private fun readSparkleAutoCheckPreferenceFromJavaPrefs(): Boolean? {
    return try {
        val prefs = Preferences.userRoot().node(SnapODefaultsDomain)
        runCatching { prefs.sync() }
        val rawValue = prefs.get(SparkleAutoCheckKey, null) ?: return null
        parseBooleanPreference(rawValue)
    } catch (_: BackingStoreException) {
        null
    } catch (_: SecurityException) {
        null
    }
}

private fun parseBooleanPreference(rawValue: String): Boolean? {
    val normalized = rawValue.trim().lowercase()
    return when (normalized) {
        "1", "true", "yes" -> true
        "0", "false", "no" -> false
        else -> null
    }
}

private fun isMacOs(): Boolean {
    return System.getProperty("os.name").startsWith("Mac")
}

private fun markPromptedIfNeeded(): Boolean {
    return try {
        val prefs = Preferences.userRoot().node(HelperPrefsNode)
        // Only ask the host app to prompt once to avoid nagging.
        val alreadyPrompted = prefs.getBoolean(PromptedForPermissionKey, false)
        if (alreadyPrompted) return false
        prefs.putBoolean(PromptedForPermissionKey, true)
        true
    } catch (_: SecurityException) {
        false
    }
}

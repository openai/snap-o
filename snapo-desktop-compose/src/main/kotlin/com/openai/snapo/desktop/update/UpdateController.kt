package com.openai.snapo.desktop.update

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

internal enum class UpdateCheckSource {
    Auto,
    Manual,
}

internal class UpdateController(
    private val checker: UpdateChecker,
    private val currentVersion: String,
    private val currentBuildNumber: String?,
    private val onUpdateAvailable: (UpdateInfo) -> Unit,
) {
    var isChecking by mutableStateOf(false)
        private set
    private var hasTriggeredUpdate = false

    suspend fun checkForUpdates(source: UpdateCheckSource) {
        if (isChecking) return
        isChecking = true
        when (val result = checker.check(currentVersion, currentBuildNumber)) {
            is UpdateCheckResult.UpdateAvailable -> {
                if (source == UpdateCheckSource.Manual || !hasTriggeredUpdate) {
                    hasTriggeredUpdate = true
                    onUpdateAvailable(result.update)
                }
            }
            UpdateCheckResult.UpToDate -> Unit
            is UpdateCheckResult.Error -> Unit
        }
        isChecking = false
    }
}

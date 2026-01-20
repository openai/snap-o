package com.openai.snapo.link.core

import android.app.ActivityManager
import android.app.Application
import android.os.Process
import android.os.SystemClock

internal class SnapOLinkContext(
    private val app: Application,
    private val config: SnapOLinkConfig,
    private val appIconProvider: AppIconProvider = AppIconProvider(app),
    featureSinkProvider: (String) -> LinkEventSink,
    private val serverStartWallMs: Long = System.currentTimeMillis(),
    private val serverStartMonoNs: Long = SystemClock.elapsedRealtimeNanos(),
) {
    @Volatile
    private var latestAppIcon: AppIcon? = null

    init {
        SnapOLinkRegistry.bindSinkProvider(featureSinkProvider)
    }

    fun buildHello(): Hello =
        Hello(
            packageName = app.packageName,
            processName = appProcessName(),
            pid = Process.myPid(),
            serverStartWallMs = serverStartWallMs,
            serverStartMonoNs = serverStartMonoNs,
            mode = config.modeLabel,
            features = SnapOLinkRegistry.snapshot().map { LinkFeatureInfo(it.featureId) },
        )

    fun latestAppIcon(): AppIcon? = latestAppIcon

    fun snapshotFeatures(): List<SnapOLinkFeature> = SnapOLinkRegistry.snapshot()

    fun loadAppIconIfAvailable(): AppIcon? {
        val iconEvent = appIconProvider.loadAppIcon() ?: return null
        latestAppIcon = iconEvent
        return iconEvent
    }

    private fun appProcessName(): String {
        return try {
            val am = app.getSystemService(Application.ACTIVITY_SERVICE) as ActivityManager
            val pid = Process.myPid()
            am.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName ?: app.packageName
        } catch (_: Throwable) {
            app.packageName
        }
    }
}

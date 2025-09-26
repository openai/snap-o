package com.openai.snapo.link.core

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Process
import kotlin.time.Duration.Companion.milliseconds

/**
 * Auto-initializes the Snap-O link server very early in app startup.
 *
 * Reads configuration from this provider’s <meta-data> in the merged manifest.
 *
 * Manifest keys (all optional):
 *  - snapo.auto_init (boolean)        default: true
 *  - snapo.main_process_only (boolean)default: true
 *  - snapo.buffer_window_ms (long)    default: 300000 (5 minutes)
 *  - snapo.max_events (int)           default: 10000
 *  - snapo.max_bytes (long)           default: 16777216 (16 MB)
 *  - snapo.mode_label (string)        default: "safe"
 *  - snapo.allow_release (boolean)    default: false (set true to keep the server in release builds)
 */
class SnapOInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val ctx = context ?: return false

        val meta = try {
            val pm = ctx.packageManager
            val provider = javaClass.name
            val cn = android.content.ComponentName(ctx.packageName, provider)
            pm.getProviderInfo(cn, PackageManager.GET_META_DATA).metaData
        } catch (_: Throwable) {
            null
        }

        val autoInit = meta?.getBoolean("snapo.auto_init", true) ?: true
        if (!autoInit) return false

        // Optionally restrict to main process
        val mainOnly = meta?.getBoolean("snapo.main_process_only", true) ?: true
        if (mainOnly && !isMainProcess(ctx)) return false

        val bufferMs = readLong(meta, "snapo.buffer_window_ms", 300_000L)
        val maxEvents = readInt(meta, "snapo.max_events", 10_000)
        val maxBytes = readLong(meta, "snapo.max_bytes", 16L * 1024 * 1024)
        val modeLabel = meta?.getString("snapo.mode_label") ?: "safe"
        val allowRelease = meta?.getBoolean("snapo.allow_release", false) ?: false

        val config = SnapONetConfig(
            bufferWindow = bufferMs.milliseconds,
            maxBufferedEvents = maxEvents,
            maxBufferedBytes = maxBytes,
            singleClientOnly = true,
            modeLabel = modeLabel,
            allowRelease = allowRelease,
        )

        // Start the server and expose it through SnapOLink
        SnapOLinkServer.start(
            ctx.applicationContext as Application,
            config = config
        )
        return true
    }

    private fun isMainProcess(ctx: Context): Boolean {
        return try {
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            val pid = Process.myPid()
            val proc = am.runningAppProcesses?.firstOrNull { it.pid == pid }
            proc?.processName == ctx.packageName
        } catch (_: Throwable) {
            // If we can’t determine, assume main to avoid silent no-op in simple apps.
            true
        }
    }

    // Helpers: meta-data values can arrive as Int, Long, or String (from placeholders).
    private fun readLong(meta: Bundle?, key: String, def: Long): Long {
        val v = meta?.get(key) ?: return def
        return when (v) {
            is Int -> v.toLong()
            is Long -> v
            is String -> v.toLongOrNull() ?: def
            else -> def
        }
    }

    private fun readInt(meta: Bundle?, key: String, def: Int): Int {
        val v = meta?.get(key) ?: return def
        return when (v) {
            is Int -> v
            is Long -> v.toInt()
            is String -> v.toIntOrNull() ?: def
            else -> def
        }
    }

    // --- Required stubs (not used) ---
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}

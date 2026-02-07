package com.openai.snapo.network

import android.app.ActivityManager
import android.content.ComponentName
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Process
import androidx.core.content.ContentProviderCompat
import kotlin.time.Duration.Companion.milliseconds

/**
 * Auto-initializes the NetworkInspector feature very early in app startup.
 *
 * Reads configuration from this provider’s <meta-data> in the merged manifest.
 *
 * Manifest keys (all optional):
 *  - snapo.auto_init (boolean)        default: true
 *  - snapo.main_process_only (boolean)default: true
 *  - snapo.buffer_window_ms (long)    default: 300000 (5 minutes)
 *  - snapo.max_events (int)           default: 10000
 *  - snapo.max_bytes (long)           default: 16777216 (16 MB)
 */
class SnapONetworkInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val ctx = ContentProviderCompat.requireContext(this)
        val meta = try {
            val pm = ctx.packageManager
            val provider = javaClass.name
            val cn = ComponentName(ctx.packageName, provider)
            pm.getProviderInfo(cn, PackageManager.GET_META_DATA).metaData
        } catch (_: Throwable) {
            null
        }

        if (!shouldInitProvider(meta)) {
            return false
        }

        val bufferMs = readLong(meta, "snapo.buffer_window_ms", 300_000L)
        val maxEvents = readInt(meta, "snapo.max_events", 10_000)
        val maxBytes = readLong(meta, "snapo.max_bytes", 16L * 1024 * 1024)

        val networkConfig = NetworkInspectorConfig(
            bufferWindow = bufferMs.milliseconds,
            maxBufferedEvents = maxEvents,
            maxBufferedBytes = maxBytes,
        )

        NetworkInspector.initialize(networkConfig)
        return true
    }

    private fun shouldInitProvider(meta: Bundle?): Boolean {
        val context = ContentProviderCompat.requireContext(this)

        val autoInit = meta?.getBoolean("snapo.auto_init", true) ?: true
        if (!autoInit) {
            return false
        }

        val mainOnly = meta?.getBoolean("snapo.main_process_only", true) ?: true
        return !mainOnly || isMainProcess(context)
    }

    private fun isMainProcess(ctx: Context): Boolean {
        return try {
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val pid = Process.myPid()
            val proc = am.runningAppProcesses?.firstOrNull { it.pid == pid }
            proc?.processName == ctx.packageName
        } catch (_: Throwable) {
            true
        }
    }

    // Helpers: meta-data values can arrive as Int, Long, or String (from placeholders).
    private fun readLong(meta: Bundle?, key: String, def: Long): Long {
        val data = meta ?: return def
        if (!data.containsKey(key)) return def
        val raw = readRawMetaValue(data, key) ?: return def
        return when (raw) {
            is Long -> raw
            is Int -> raw.toLong()
            is Short -> raw.toLong()
            is Byte -> raw.toLong()
            is String -> raw.toLongOrNull() ?: def
            else -> def
        }
    }

    private fun readInt(meta: Bundle?, key: String, def: Int): Int {
        val data = meta ?: return def
        if (!data.containsKey(key)) return def
        val raw = readRawMetaValue(data, key) ?: return def
        return when (raw) {
            is Int -> raw
            is Long -> raw.toInt()
            is Short -> raw.toInt()
            is Byte -> raw.toInt()
            is String -> raw.toIntOrNull() ?: def
            else -> def
        }
    }

    @Suppress("DEPRECATION")
    private fun readRawMetaValue(bundle: Bundle, key: String): Any? = bundle.get(key)

    // --- Required stubs (not used) ---
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}

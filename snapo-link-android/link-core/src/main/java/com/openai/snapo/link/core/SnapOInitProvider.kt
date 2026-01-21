package com.openai.snapo.link.core

import android.app.ActivityManager
import android.app.Application
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

/**
 * Auto-initializes the Snap-O link server very early in app startup.
 *
 * Reads configuration from this provider’s <meta-data> in the merged manifest.
 *
 * Manifest keys (all optional):
 *  - snapo.auto_init (boolean)        default: true
 *  - snapo.main_process_only (boolean)default: true
 *  - snapo.mode_label (string)        default: "safe"
 *  - snapo.allow_release (boolean)    default: false (set true to keep the server in release builds)
 */
class SnapOInitProvider : ContentProvider() {

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

        val modeLabel = meta?.getString("snapo.mode_label") ?: "safe"
        val allowRelease = meta?.getBoolean("snapo.allow_release", false) ?: false

        val linkConfig = SnapOLinkConfig(
            modeLabel = modeLabel,
            allowRelease = allowRelease,
        )

        SnapOLinkServer.start(
            ctx.applicationContext as Application,
            config = linkConfig
        )
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
            // If we can’t determine, assume main to avoid silent no-op in simple apps.
            true
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

package com.openai.snapo.tweaks

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.util.Log
import com.openai.snapo.tweaks.internal.TweakAppInfoProvider
import com.openai.snapo.tweaks.internal.TweakHttpServer
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import java.io.IOException

/** Enables live tweaks for debuggable apps or explicitly opted-in release apps. */
internal class SnapOTweaksInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val applicationContext = context?.applicationContext ?: return false
        val applicationInfo = applicationInfoWithMetadata(applicationContext)
        val isDebuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        val allowRelease = applicationInfo.metaData?.getBoolean(AllowReleaseMetadata, false) == true

        if (!TweaksRuntimePolicy.configure(isDebuggable, allowRelease)) {
            return false
        }

        return TweaksRuntime.start(applicationContext)
    }

    private fun applicationInfoWithMetadata(context: Context): ApplicationInfo = try {
        context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
    } catch (_: PackageManager.NameNotFoundException) {
        context.applicationInfo
    } catch (_: SecurityException) {
        context.applicationInfo
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    private companion object {
        const val AllowReleaseMetadata = "snapo.tweaks.allow_release"
    }
}

private object TweaksRuntime {
    @Volatile
    private var server: TweakHttpServer? = null

    @Synchronized
    fun start(context: Context): Boolean {
        if (server != null) {
            return true
        }

        return try {
            val startedServer = TweakHttpServer(
                appInfoProvider = TweakAppInfoProvider(context),
            )
            startedServer.start()
            server = startedServer
            true
        } catch (error: IOException) {
            Log.e("SnapOTweaks", "Could not start the Snap-O Tweaks server.", error)
            false
        }
    }
}

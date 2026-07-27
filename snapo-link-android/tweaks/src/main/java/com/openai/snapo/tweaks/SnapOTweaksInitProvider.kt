package com.openai.snapo.tweaks

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.database.Cursor
import android.net.Uri
import android.util.Log
import com.openai.snapo.tweaks.internal.TweakAppInfoProvider
import com.openai.snapo.tweaks.internal.TweakHttpServer
import java.io.IOException

/** Starts the local Snap-O Tweaks server only in a debuggable application. */
class SnapOTweaksInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val applicationContext = context?.applicationContext ?: return false
        if (applicationContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            return false
        }

        return TweaksRuntime.start(applicationContext)
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

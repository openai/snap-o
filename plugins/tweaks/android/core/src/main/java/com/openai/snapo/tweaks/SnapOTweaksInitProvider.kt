package com.openai.snapo.tweaks

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import com.openai.snapo.plugin.PluginStartupPolicy
import com.openai.snapo.tweaks.internal.TweakHttpServer
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy

/** Enables live tweaks for debuggable apps or explicitly opted-in release apps. */
internal class SnapOTweaksInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val applicationContext = context?.applicationContext ?: return false
        val allowed = PluginStartupPolicy.isAllowed(applicationContext, AllowReleaseMetadata)
        if (!TweaksRuntimePolicy.configureAllowed(allowed)) {
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

        val candidate = TweakHttpServer()
        return candidate.start(context).also { started ->
            if (started) server = candidate
        }
    }
}

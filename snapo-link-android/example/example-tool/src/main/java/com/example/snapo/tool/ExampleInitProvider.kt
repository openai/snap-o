package com.example.snapo.tool

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.util.Log
import com.openai.snapo.inspector.InspectorServer
import com.openai.snapo.inspector.InspectorStartupPolicy
import java.io.IOException

/** The example is a debug-only dependency. This check also prevents accidental release startup. */
class ExampleInitProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val app = context?.applicationContext ?: return false
        if (!InspectorStartupPolicy.isAllowed(app, "snapo.example.allow_release")) return false
        return ExampleRuntime.start()
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}

private object ExampleRuntime {
    private var server: InspectorServer? = null

    @Synchronized
    fun start(): Boolean {
        if (server != null) return true
        return try {
            server = exampleServer().also { it.start() }
            true
        } catch (failure: IOException) {
            Log.e("SnapOExample", "Could not start the Example tool.", failure)
            false
        }
    }
}

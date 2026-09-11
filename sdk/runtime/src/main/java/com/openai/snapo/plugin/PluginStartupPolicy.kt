package com.openai.snapo.plugin

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager

object PluginStartupPolicy {
    fun isAllowed(
        isDebuggable: Boolean,
        allowRelease: Boolean,
        applicationAllowsRelease: Boolean = false,
    ): Boolean = isDebuggable || allowRelease || applicationAllowsRelease

    fun isAllowed(context: Context, releaseMetadataKey: String, allowRelease: Boolean = false): Boolean {
        val info = applicationInfo(context)
        return isAllowed(
            isDebuggable = info.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0,
            allowRelease = allowRelease,
            applicationAllowsRelease = info.metaData?.getBoolean(releaseMetadataKey, false) == true,
        )
    }

    private fun applicationInfo(context: Context): ApplicationInfo = try {
        context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
    } catch (_: PackageManager.NameNotFoundException) {
        context.applicationInfo
    } catch (_: SecurityException) {
        context.applicationInfo
    }
}

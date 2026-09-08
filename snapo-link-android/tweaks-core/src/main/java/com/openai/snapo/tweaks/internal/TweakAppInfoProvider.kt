package com.openai.snapo.tweaks.internal

import android.content.Context
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream

internal data class TweakAppInfo(
    val name: String,
    val packageName: String,
)

internal class TweakAppInfoProvider(context: Context) {
    private val applicationContext = context.applicationContext

    private val appInfo: TweakAppInfo by lazy {
        TweakAppInfo(
            name = loadName(),
            packageName = applicationContext.packageName,
        )
    }

    private val appIcon: ByteArray? by lazy { renderIcon() }

    fun load(): TweakAppInfo = appInfo

    fun loadIcon(): ByteArray? = appIcon

    private fun loadName(): String = try {
        applicationContext.packageManager
            .getApplicationLabel(applicationContext.applicationInfo)
            .toString()
            .ifBlank { applicationContext.packageName }
    } catch (_: Resources.NotFoundException) {
        applicationContext.packageName
    } catch (_: SecurityException) {
        applicationContext.packageName
    }

    private fun renderIcon(): ByteArray? = try {
        val drawable = applicationContext.packageManager
            .getApplicationIcon(applicationContext.applicationInfo)
        val bitmap = Bitmap.createBitmap(
            TARGET_ICON_SIZE,
            TARGET_ICON_SIZE,
            Bitmap.Config.ARGB_8888,
        )

        try {
            drawable.setBounds(0, 0, TARGET_ICON_SIZE, TARGET_ICON_SIZE)
            drawable.draw(Canvas(bitmap))
            encodeIcon(bitmap)
        } finally {
            bitmap.recycle()
        }
    } catch (_: Resources.NotFoundException) {
        null
    } catch (_: SecurityException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    private fun encodeIcon(bitmap: Bitmap): ByteArray? = ByteArrayOutputStream().use { stream ->
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, ICON_PNG_QUALITY, stream)) {
            null
        } else {
            stream.toByteArray()
        }
    }

    private companion object {
        const val TARGET_ICON_SIZE = 96
        const val ICON_PNG_QUALITY = 100
    }
}

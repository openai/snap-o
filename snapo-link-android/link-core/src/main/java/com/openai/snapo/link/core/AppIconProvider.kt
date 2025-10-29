package com.openai.snapo.link.core

import android.app.Application
import android.content.pm.PackageManager
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.util.Base64
import androidx.core.graphics.createBitmap
import androidx.core.graphics.scale
import java.io.ByteArrayOutputStream

internal class AppIconProvider(private val app: Application) {

    fun loadAppIcon(): AppIcon? {
        val drawable = try {
            app.packageManager.getApplicationIcon(app.applicationInfo)
        } catch (_: PackageManager.NameNotFoundException) {
            return null
        } catch (_: Resources.NotFoundException) {
            return null
        } catch (_: SecurityException) {
            return null
        }

        return try {
            drawableToBitmap(drawable)?.let { bitmap ->
                val scaled =
                    if (bitmap.width == TARGET_ICON_SIZE && bitmap.height == TARGET_ICON_SIZE) {
                        bitmap
                    } else {
                        bitmap.scale(TARGET_ICON_SIZE, TARGET_ICON_SIZE)
                    }

                val pngData = ByteArrayOutputStream().use { out ->
                    scaled.compress(Bitmap.CompressFormat.PNG, ICON_PNG_QUALITY, out)
                    out.toByteArray()
                }
                if (scaled !== bitmap && !scaled.isRecycled) {
                    scaled.recycle()
                }
                val encoded = Base64.encodeToString(pngData, Base64.NO_WRAP)

                AppIcon(
                    packageName = app.packageName,
                    width = TARGET_ICON_SIZE,
                    height = TARGET_ICON_SIZE,
                    base64Data = encoded,
                )
            }
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        if (drawable is BitmapDrawable) {
            return drawable.bitmap
        }
        return renderDrawable(drawable)
    }

    private fun renderDrawable(drawable: Drawable): Bitmap {
        val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: TARGET_ICON_SIZE
        val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: TARGET_ICON_SIZE
        val bitmap = createBitmap(width, height)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }

    private companion object {
        private const val TARGET_ICON_SIZE = 96
        private const val ICON_PNG_QUALITY = 100
    }
}

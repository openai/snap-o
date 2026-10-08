package com.openai.snapo.demo.tweaks.views

import android.content.Context
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Paint
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.viewModels
import androidx.lifecycle.ViewModel
import com.openai.snapo.tweaks.TweakScope
import com.openai.snapo.tweaks.views.bindTweak

class PreviewViewModel : ViewModel() {
    private val tweaks = TweakScope()
    private val shapeSource = ShapeSource()
    val shape = tweaks.tweak(shapeSource, "Shape/Kind")
    val radius = tweaks.tweak(64f, "Shape/Radius", 16f..128f)
    val blur = tweaks.tweak(12f, "Shape/Blur", 0f..32f)
    val color = tweaks.tweakColor(0xFF526DDE.toInt(), "Shape/Color")

    init {
        addCloseable(tweaks)
    }

    fun toggleShape() = shapeSource.toggle()
}

class MainActivity : ComponentActivity() {
    private val model: PreviewViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val density = resources.displayMetrics.density
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (24 * density).toInt()
            setPadding(padding, 0, padding, 0)
        }
        header.addView(
            TextView(this).apply {
                text = "Views and ViewModels"
                textSize = 24f
            }
        )
        header.addView(
            TextView(this).apply {
                text = "Adjust the shape in Snap-O. Rotate the device to keep the ViewModel's tweaks."
                textSize = 16f
            }
        )
        header.addView(
            Button(this).apply {
                setOnClickListener { model.toggleShape() }
                bindTweak(model.shape) { text = "Change shape (${it.name})" }
            }
        )
        content.addView(header)
        val preview = ShapeView(this)
        preview.bindTweak(model.shape) { preview.shape = it }
        preview.bindTweak(model.radius) { preview.radiusDp = it }
        preview.bindTweak(model.blur) { preview.setBlur(it) }
        preview.bindTweak(model.color) { preview.setColor(it) }
        content.addView(preview, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(content)
    }
}

private class ShapeView(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    var shape = ShapeKind.Circle
        set(value) {
            field = value
            invalidate()
        }
    var radiusDp = 64f
        set(value) {
            field = value
            invalidate()
        }

    init {
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun setBlur(radiusDp: Float) {
        paint.maskFilter = if (radiusDp > 0) {
            BlurMaskFilter(radiusDp * resources.displayMetrics.density, BlurMaskFilter.Blur.NORMAL)
        } else {
            null
        }
        invalidate()
    }

    fun setColor(color: Int) {
        paint.color = color
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val centerX = width / 2f
        val centerY = height / 2f
        val radius = radiusDp * resources.displayMetrics.density
        when (shape) {
            ShapeKind.Circle -> canvas.drawCircle(centerX, centerY, radius, paint)
            ShapeKind.Square -> canvas.drawRect(
                centerX - radius,
                centerY - radius,
                centerX + radius,
                centerY + radius,
                paint,
            )
        }
    }
}

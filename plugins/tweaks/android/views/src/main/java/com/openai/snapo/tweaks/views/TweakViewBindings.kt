package com.openai.snapo.tweaks.views

import android.view.View
import androidx.annotation.MainThread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.Closeable

/**
 * Applies the current value and subsequent changes on main while this view is attached.
 * Install once. Closing removes the binding permanently without closing the tweak's owner.
 * Attachment does not imply visibility; a GONE view can still be attached.
 */
@MainThread
fun <T> View.bindTweak(value: StateFlow<T>, onChange: (T) -> Unit): Closeable {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    var collection: Job? = null
    val listener = object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(view: View) {
            collection?.cancel()
            collection = scope.launch { value.collect(onChange) }
        }

        override fun onViewDetachedFromWindow(view: View) {
            collection?.cancel()
            collection = null
        }
    }
    addOnAttachStateChangeListener(listener)
    if (isAttachedToWindow) listener.onViewAttachedToWindow(this)
    return Closeable {
        removeOnAttachStateChangeListener(listener)
        scope.cancel()
    }
}

package com.openai.snapo.tweaks

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.openai.snapo.tweaks.internal.TweakRegistry
import com.openai.snapo.tweaks.internal.TweaksRuntimePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakViewModelTest {
    @Test
    fun `ViewModel owns registration independently of collectors and closes at clear`() {
        TweaksRuntimePolicy.configure(isDebuggable = true, allowRelease = false)
        val store = ViewModelStore()
        val factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = PreviewViewModel() as T
        }
        try {
            val first = ViewModelProvider(store, factory)[PreviewViewModel::class.java]
            TweakRegistry.update(mapOf("Radius" to 32))
            val recreatedProvider = ViewModelProvider(store, factory)
            assertSame(first, recreatedProvider[PreviewViewModel::class.java])
            assertEquals(32f, first.radius.value)
            store.clear()
            assertTrue(TweakRegistry.snapshot().isEmpty())
        } finally {
            store.clear()
            TweakRegistry.clear()
            TweaksRuntimePolicy.configure(isDebuggable = false, allowRelease = false)
        }
    }

    private class PreviewViewModel : ViewModel() {
        private val tweaks = TweakScope()
        val radius = tweaks.tweak(16f, "Radius")

        init {
            addCloseable(tweaks)
        }
    }
}

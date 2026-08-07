package com.openai.snapo.demo.tweaks

import android.content.SharedPreferences
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import com.openai.snapo.tweaks.TweakSource
import com.openai.snapo.tweaks.tweak
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

internal class SharedPreferencesBooleanSource(
    private val preferences: SharedPreferences,
    private val key: String,
    private val default: Boolean,
) : TweakSource<Boolean> {

    override var value: Boolean
        get() = preferences.getBoolean(key, default)
        set(value) {
            preferences.edit().putBoolean(key, value).apply()
        }

    override val isModified: Boolean
        get() = preferences.contains(key)

    override fun reset() {
        preferences.edit().remove(key).apply()
    }

    override fun observe(): Flow<Unit> = callbackFlow {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, changedKey ->
            if (changedKey == key || changedKey == null) trySend(Unit)
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }
}

@Composable
internal fun SharedPreferences.tweak(
    key: String,
    default: Boolean,
    name: String = key,
): State<Boolean> {
    val source = remember(this, key, default) {
        SharedPreferencesBooleanSource(this, key, default)
    }
    return tweak(source, name)
}

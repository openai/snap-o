package com.openai.snapo.tweaks.internal

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

class TweakRegistrySnapshotTest {
    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `unrelated Compose state changes do not notify registry observers`() {
        val name = "Motion/Duration"
        TweakRegistry.register(TweakDescriptor(name, TweakType.INT, 400))
        val unrelatedState = mutableStateOf(0)
        var notifications = 0

        TweakRegistry.observeChanges { notifications++ }.use {
            Snapshot.withMutableSnapshot { unrelatedState.value = 1 }
            Snapshot.sendApplyNotifications()
            assertEquals(0, notifications)

            TweakRegistry.update(mapOf(name to 550))
            assertEquals(1, notifications)
            assertEquals(550, TweakRegistry.snapshot().single().value)
        }
    }
}

package com.openai.snapo.tweaks

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import com.openai.snapo.tweaks.internal.TweakRegistry
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TweakSourceObservationTest {

    @After
    fun clearRegistry() {
        TweakRegistry.clear()
    }

    @Test
    fun `source observation follows the first owner and its promoted replacement`() = runBlocking {
        var firstReads = 0
        var secondReads = 0
        val firstChanges = MutableSharedFlow<Unit>()
        val secondChanges = MutableSharedFlow<Unit>()
        val firstSource = testTweakSource(
            read = {
                firstReads += 1
                false
            },
            changes = firstChanges,
        )
        val secondSource = testTweakSource(
            read = { true.also { secondReads += 1 } },
            changes = secondChanges,
        )
        val first = TweakRegistration(
            ExternalTweakBinding("Lifecycle observed owner", mutableStateOf(firstSource)),
        )
        val second = TweakRegistration(
            ExternalTweakBinding("Lifecycle observed owner", mutableStateOf(secondSource)),
        )
        first.onRemembered()
        second.onRemembered()
        val firstCollection = launch(start = CoroutineStart.UNDISPATCHED) {
            first.observeSource(firstSource)
        }
        val secondCollection = launch(start = CoroutineStart.UNDISPATCHED) {
            second.observeSource(secondSource)
        }
        firstChanges.awaitSubscriptions(1)

        assertEquals(0, firstReads)
        assertEquals(1, firstChanges.subscriptionCount.value)
        assertEquals(0, secondChanges.subscriptionCount.value)

        firstChanges.emit(Unit)
        yield()

        assertEquals(0, firstReads)
        assertEquals(0, secondReads)

        first.onForgotten()
        Snapshot.sendApplyNotifications()
        firstChanges.awaitSubscriptions(0)
        secondChanges.awaitSubscriptions(1)

        assertEquals(0, firstChanges.subscriptionCount.value)
        assertEquals(1, secondChanges.subscriptionCount.value)
        assertEquals(0, secondReads)

        secondCollection.cancel()
        secondChanges.awaitSubscriptions(0)

        assertEquals(0, secondChanges.subscriptionCount.value)
        second.onForgotten()
        firstCollection.cancel()
    }

    @Test
    fun `source observation publishes status changes without changing its value`() = runBlocking {
        var modified = false
        var reads = 0
        var statusReads = 0
        val changes = MutableSharedFlow<Unit>()
        val owner = testTweakSource(
            read = { false.also { reads += 1 } },
            modified = { modified.also { statusReads += 1 } },
            changes = changes,
        )
        val registration = TweakRegistration(
            ExternalTweakBinding("Lifecycle observed status", mutableStateOf(owner)),
        )
        registration.onRemembered()
        val collection = launch(start = CoroutineStart.UNDISPATCHED) {
            registration.observeSource(owner)
        }
        changes.awaitSubscriptions(1)

        assertEquals(0, reads)
        assertEquals(0, statusReads)
        assertEquals(false, registration.value)
        assertEquals(1, reads)
        assertEquals(1, statusReads)

        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }

        modified = true
        changes.emit(Unit)
        yield()

        assertEquals(1, notifications)
        assertEquals(false, registration.value)
        assertTrue(TweakRegistry.snapshot().single().modified)
        assertEquals(2, reads)
        assertEquals(2, statusReads)

        collection.cancel()
        observer.close()
        registration.onForgotten()
    }

    @Test
    fun `replacing an observed source refreshes its cached value and status`() = runBlocking {
        var firstReads = 0
        var replacementReads = 0
        var replacementStatusReads = 0
        val firstChanges = MutableSharedFlow<Unit>()
        val replacementChanges = MutableSharedFlow<Unit>()
        val firstSource = testTweakSource(
            read = { false.also { firstReads += 1 } },
            changes = firstChanges,
        )
        val replacement = testTweakSource(
            read = { true.also { replacementReads += 1 } },
            modified = { true.also { replacementStatusReads += 1 } },
            changes = replacementChanges,
        )
        val currentSource = mutableStateOf(firstSource)
        val registration = TweakRegistration(
            ExternalTweakBinding("Lifecycle replacement owner", currentSource),
        )
        registration.onRemembered()
        var notifications = 0
        val observer = TweakRegistry.observeChanges { notifications += 1 }
        val firstCollection = launch(start = CoroutineStart.UNDISPATCHED) {
            registration.observeSource(firstSource)
        }
        firstChanges.awaitSubscriptions(1)

        assertEquals(0, notifications)
        assertEquals(0, firstReads)
        assertEquals(false, TweakRegistry.snapshot().single().value)
        assertEquals(1, firstReads)

        currentSource.value = replacement
        firstCollection.cancel()
        firstChanges.awaitSubscriptions(0)
        val replacementCollection = launch(start = CoroutineStart.UNDISPATCHED) {
            registration.observeSource(replacement)
        }
        replacementChanges.awaitSubscriptions(1)

        assertEquals(1, notifications)
        assertEquals(1, replacementReads)
        assertEquals(1, replacementStatusReads)
        val snapshot = TweakRegistry.snapshot().single()
        assertEquals(true, snapshot.value)
        assertTrue(snapshot.modified)
        assertEquals(1, replacementReads)
        assertEquals(1, replacementStatusReads)

        replacementCollection.cancel()
        observer.close()
        registration.onForgotten()
    }

    @Test
    fun `replacing and notifying an unobserved source does not initialize its owner`() = runBlocking {
        var replacementReads = 0
        var replacementStatusReads = 0
        val firstChanges = MutableSharedFlow<Unit>()
        val replacementChanges = MutableSharedFlow<Unit>()
        val first = testTweakSource(read = { false }, changes = firstChanges)
        val replacement = testTweakSource(
            read = { true.also { replacementReads += 1 } },
            modified = { true.also { replacementStatusReads += 1 } },
            changes = replacementChanges,
        )
        val latestSource = mutableStateOf(first)
        val registration = TweakRegistration(
            ExternalTweakBinding("Lifecycle cold replacement", latestSource),
        )
        registration.onRemembered()
        val firstCollection = launch(start = CoroutineStart.UNDISPATCHED) {
            registration.observeSource(first)
        }
        firstChanges.awaitSubscriptions(1)
        latestSource.value = replacement
        firstCollection.cancel()
        firstChanges.awaitSubscriptions(0)

        val replacementCollection = launch(start = CoroutineStart.UNDISPATCHED) {
            registration.observeSource(replacement)
        }
        replacementChanges.awaitSubscriptions(1)
        replacementChanges.emit(Unit)
        yield()

        assertEquals(0, replacementReads)
        assertEquals(0, replacementStatusReads)
        assertEquals(true, registration.value)
        assertEquals(1, replacementReads)
        assertEquals(1, replacementStatusReads)

        replacementCollection.cancel()
        registration.onForgotten()
    }

    @Test
    fun `owner edits and reset refresh the effective authoritative value`() {
        var value = 3
        var upstream = 3
        var modified = false
        val owner = testTweakSource(
            read = { value },
            onValueChange = { requested ->
                value = requested.coerceIn(0, 10)
                modified = true
            },
            onReset = {
                value = upstream
                modified = false
            },
            modified = { modified },
        )
        val name = "Lifecycle authoritative owner"
        val registration = TweakRegistration(ExternalTweakBinding(name, mutableStateOf(owner)))
        registration.onRemembered()

        assertEquals(3, registration.value)

        val edited = TweakRegistry.update(mapOf(name to 20)).single()

        assertEquals(10, registration.value)
        assertEquals(10, edited.value)
        assertTrue(edited.modified)

        upstream = 7
        val reset = TweakRegistry.update(mapOf(name to null)).single()

        assertEquals(7, registration.value)
        assertEquals(7, reset.value)
        assertEquals(false, reset.modified)

        registration.onForgotten()
    }
}

internal fun <T : Any> testTweakSource(
    read: () -> T,
    onValueChange: (T) -> Unit = {},
    onReset: () -> Unit = {},
    modified: () -> Boolean = { false },
    changes: Flow<Unit> = emptyFlow(),
): TweakSource<T> = object : TweakSource<T> {
    override var value: T
        get() = read()
        set(updated) {
            onValueChange(updated)
        }

    override val isModified: Boolean
        get() = modified()

    override fun reset() = onReset()

    override fun observe(): Flow<Unit> = changes
}

internal fun <T : Any> testTweakBinding(
    name: String,
    source: TweakSource<T>,
): ExternalTweakBinding<T> = ExternalTweakBinding(name, mutableStateOf(source))

private suspend fun MutableSharedFlow<Unit>.awaitSubscriptions(expected: Int) {
    withTimeout(1_000) {
        while (subscriptionCount.value != expected) {
            yield()
        }
    }
}

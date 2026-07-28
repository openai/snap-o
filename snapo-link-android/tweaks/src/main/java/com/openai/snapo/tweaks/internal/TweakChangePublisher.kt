package com.openai.snapo.tweaks.internal

import java.io.Closeable
import java.util.concurrent.LinkedBlockingDeque

internal class TweakChangePublisher(
    private val schedule: (Runnable) -> Boolean,
) : Closeable {
    private val lock = Any()
    private val subscriptions = LinkedHashMap<Long, LinkedBlockingDeque<List<TweakSnapshot>>>()
    private var nextSubscriptionId = 0L
    private var publicationScheduled = false
    private var closed = false

    fun subscribe(): Subscription = synchronized(lock) {
        check(!closed) { "The tweak change publisher is closed." }

        val id = nextSubscriptionId++
        val events = LinkedBlockingDeque<List<TweakSnapshot>>(1)
        subscriptions[id] = events

        Subscription(
            initial = TweakRegistry.snapshot(),
            events = events,
            onClose = { synchronized(lock) { subscriptions.remove(id) } },
        )
    }

    fun notifyChanged() {
        val shouldSchedule = synchronized(lock) {
            if (closed || publicationScheduled || subscriptions.isEmpty()) {
                false
            } else {
                publicationScheduled = true
                true
            }
        }

        if (shouldSchedule && !schedule(Runnable(::publish))) {
            synchronized(lock) { publicationScheduled = false }
        }
    }

    override fun close() {
        synchronized(lock) {
            closed = true
            publicationScheduled = false
            subscriptions.clear()
        }
    }

    private fun publish() {
        val snapshot = TweakRegistry.snapshot()

        synchronized(lock) {
            publicationScheduled = false
            if (closed) return

            subscriptions.values.forEach { events ->
                if (!events.offer(snapshot)) {
                    events.poll()
                    events.offer(snapshot)
                }
            }
        }
    }

    internal class Subscription(
        val initial: List<TweakSnapshot>,
        val events: LinkedBlockingDeque<List<TweakSnapshot>>,
        private val onClose: () -> Unit,
    ) : Closeable {
        override fun close() = onClose()
    }
}

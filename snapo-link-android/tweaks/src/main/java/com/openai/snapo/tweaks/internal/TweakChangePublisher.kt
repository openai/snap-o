package com.openai.snapo.tweaks.internal

import java.io.Closeable
import java.util.concurrent.LinkedBlockingDeque

internal class TweakChangePublisher(
    private val schedule: (Runnable) -> Boolean,
    private val snapshot: () -> List<TweakSnapshot>,
) : Closeable {
    constructor(schedule: (Runnable) -> Boolean) : this(
        schedule = schedule,
        snapshot = TweakRegistry::snapshot,
    )

    private val lock = Any()
    private val subscriptions = LinkedHashMap<Long, LinkedBlockingDeque<List<TweakSnapshot>>>()
    private var nextSubscriptionId = 0L
    private var changedSincePublicationStarted = false
    private var publicationScheduled = false
    private var closed = false

    fun subscribe(): Subscription = synchronized(lock) {
        check(!closed) { "The tweak change publisher is closed." }

        val id = nextSubscriptionId++
        val events = LinkedBlockingDeque<List<TweakSnapshot>>(1)
        subscriptions[id] = events

        Subscription(
            initial = snapshot(),
            events = events,
            onClose = { synchronized(lock) { subscriptions.remove(id) } },
        )
    }

    fun notifyChanged() {
        val shouldSchedule = synchronized(lock) {
            if (closed) {
                false
            } else if (publicationScheduled) {
                changedSincePublicationStarted = true
                false
            } else if (subscriptions.isEmpty()) {
                false
            } else {
                publicationScheduled = true
                true
            }
        }

        if (shouldSchedule) schedulePublication()
    }

    override fun close() {
        synchronized(lock) {
            closed = true
            publicationScheduled = false
            subscriptions.clear()
        }
    }

    private fun publish() {
        synchronized(lock) {
            if (closed) {
                publicationScheduled = false
                return
            }
            changedSincePublicationStarted = false
        }
        val snapshot = snapshot()

        val shouldSchedule = synchronized(lock) {
            if (closed) {
                publicationScheduled = false
                false
            } else {
                subscriptions.values.forEach { events ->
                    if (!events.offer(snapshot)) {
                        events.poll()
                        events.offer(snapshot)
                    }
                }

                if (changedSincePublicationStarted) {
                    changedSincePublicationStarted = false
                    true
                } else {
                    publicationScheduled = false
                    false
                }
            }
        }

        if (shouldSchedule) schedulePublication()
    }

    private fun schedulePublication() {
        if (!schedule(Runnable(::publish))) {
            synchronized(lock) { publicationScheduled = false }
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

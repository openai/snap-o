package com.openai.snapo.network

import com.openai.snapo.link.core.ClientId
import com.openai.snapo.link.core.EventPriority
import com.openai.snapo.link.core.LinkEventSink
import com.openai.snapo.link.core.SnapOLinkFeature
import com.openai.snapo.link.core.SnapOLinkRegistry
import com.openai.snapo.network.record.ResponseReceived
import com.openai.snapo.network.record.SnapONetRecord
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

data class NetworkInspectorConfig(
    /** Keep only the last this-many milliseconds of events in memory. */
    val bufferWindow: Duration = 5.minutes,

    /** Hard caps to avoid runaway memory. */
    val maxBufferedEvents: Int = 10_000,
    val maxBufferedBytes: Long = 16L * 1024 * 1024, // rough estimate based on encoded length
)

class NetworkInspectorFeature(
    config: NetworkInspectorConfig = NetworkInspectorConfig(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) : SnapOLinkFeature {

    override val featureId: String = "network"
    private val bufferLock = Mutex()
    private val eventBuffer = EventBuffer(config)

    @Volatile
    private var sink: NetworkEventSink? = null

    override fun onLinkAvailable(sink: LinkEventSink) {
        this.sink = NetworkEventSink(sink)
    }

    override suspend fun onFeatureOpened(clientId: Long) {
        val current = sink ?: return
        val target = ClientId.Specific(clientId)

        val deferredBodies = mutableListOf<ResponseReceived>()
        val snapshot = bufferLock.withLock { eventBuffer.snapshot() }
        for (record in snapshot) {
            if (record is ResponseReceived && record.hasBodyPayload()) {
                current.send(record.withoutBodyPayload(), clientId = target)
                deferredBodies.add(record)
            } else {
                current.send(record, clientId = target)
            }
        }
        scheduleDeferredBodies(current, target, deferredBodies)
    }

    suspend fun publish(record: SnapONetRecord) {
        bufferLock.withLock {
            eventBuffer.append(record)
        }
        val currentSink = sink ?: return
        when (record) {
            is ResponseReceived -> {
                if (record.hasBodyPayload()) {
                    currentSink.send(record.withoutBodyPayload())
                    scheduleResponseBody(currentSink, record)
                } else {
                    currentSink.send(record)
                }
            }

            else -> currentSink.send(record)
        }
    }

    private fun scheduleDeferredBodies(
        sink: NetworkEventSink,
        target: ClientId,
        deferredBodies: List<ResponseReceived>,
    ) {
        deferredBodies.forEachIndexed { index, response ->
            val stagger = ResponseBodyStaggerMillis * index
            scheduleResponseBody(sink, response, target, ResponseBodyDelayMillis + stagger)
        }
    }

    private fun scheduleResponseBody(
        sink: NetworkEventSink,
        record: ResponseReceived,
        target: ClientId = ClientId.All,
        initialDelayMs: Long = ResponseBodyDelayMillis,
    ) {
        scope.launch(Dispatchers.IO) {
            try {
                if (initialDelayMs > 0) {
                    delay(initialDelayMs)
                }
                sink.send(record, clientId = target, priority = EventPriority.Low)
            } catch (t: CancellationException) {
                throw t
            } catch (_: Throwable) {
            }
        }
    }

    private fun ResponseReceived.hasBodyPayload(): Boolean {
        if (!body.isNullOrEmpty()) return true
        return false
    }

    private fun ResponseReceived.withoutBodyPayload(): ResponseReceived =
        copy(body = null)
}

object NetworkInspector {
    @Volatile
    private var feature: NetworkInspectorFeature? = null

    /** Create and register the feature; idempotent. */
    fun initialize(config: NetworkInspectorConfig = NetworkInspectorConfig()): NetworkInspectorFeature {
        feature?.let { return it }
        return synchronized(this) {
            feature ?: NetworkInspectorFeature(config).also {
                feature = it
                SnapOLinkRegistry.register(it)
            }
        }
    }

    /** Return the active feature, or null if not initialized. */
    fun getOrNull(): NetworkInspectorFeature? = feature
}

private const val ResponseBodyDelayMillis = 200L
private const val ResponseBodyStaggerMillis = 25L

private class NetworkEventSink(
    private val delegate: LinkEventSink,
) {
    fun send(
        record: SnapONetRecord,
        clientId: ClientId = ClientId.All,
        priority: EventPriority = EventPriority.High,
    ) {
        delegate.send(record, SnapONetRecord.serializer(), clientId, priority)
    }
}

package com.openai.snapo.network

import com.openai.snapo.link.core.LinkEventSink
import com.openai.snapo.link.core.SnapOLinkFeature
import com.openai.snapo.link.core.SnapOLinkRegistry
import com.openai.snapo.link.core.sendHighPriority
import com.openai.snapo.link.core.sendLowPriority
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
    private val config: NetworkInspectorConfig = NetworkInspectorConfig(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) : SnapOLinkFeature {

    override val featureId: String = "network"
    private val bufferLock = Mutex()
    private val eventBuffer = EventBuffer(config)

    @Volatile
    private var sink: RecordSink? = null

    override suspend fun onClientConnected(sink: LinkEventSink) {
        val recordSink = RecordSink(sink)
        this.sink = recordSink
        val deferredBodies = mutableListOf<ResponseReceived>()
        val snapshot: List<SnapONetRecord> = bufferLock.withLock { eventBuffer.snapshot() }
        for (record in snapshot) {
            if (record is ResponseReceived && record.hasBodyPayload()) {
                recordSink.high(record.withoutBodyPayload())
                deferredBodies.add(record)
            } else {
                recordSink.high(record)
            }
        }
        scheduleDeferredBodies(recordSink, deferredBodies)
    }

    override fun onClientDisconnected() {
        sink = null
    }

    suspend fun publish(record: SnapONetRecord) {
        bufferLock.withLock {
            eventBuffer.append(record)
        }
        val currentSink = sink ?: return
        when (record) {
            is ResponseReceived -> {
                if (record.hasBodyPayload()) {
                    currentSink.high(record.withoutBodyPayload())
                    scheduleResponseBody(currentSink, record)
                } else {
                    currentSink.high(record)
                }
            }

            else -> currentSink.high(record)
        }
    }

    private fun scheduleDeferredBodies(
        sink: RecordSink,
        deferredBodies: List<ResponseReceived>,
    ) {
        deferredBodies.forEachIndexed { index, response ->
            val stagger = ResponseBodyStaggerMillis * index
            scheduleResponseBody(sink, response, ResponseBodyDelayMillis + stagger)
        }
    }

    private fun scheduleResponseBody(
        sink: RecordSink,
        record: ResponseReceived,
        initialDelayMs: Long = ResponseBodyDelayMillis,
    ) {
        scope.launch(Dispatchers.IO) {
            try {
                if (initialDelayMs > 0) {
                    delay(initialDelayMs)
                }
                if (this@NetworkInspectorFeature.sink !== sink) return@launch
                sink.low(record)
            } catch (t: CancellationException) {
                throw t
            } catch (_: Throwable) {
            }
        }
    }

    private fun ResponseReceived.hasBodyPayload(): Boolean {
        if (!body.isNullOrEmpty()) return true
        if (!bodyPreview.isNullOrEmpty()) return true
        return false
    }

    private fun ResponseReceived.withoutBodyPayload(): ResponseReceived =
        copy(bodyPreview = null, body = null)
}

private class RecordSink(private val delegate: LinkEventSink) {
    suspend fun high(record: SnapONetRecord) {
        delegate.sendHighPriority(record)
    }

    suspend fun low(record: SnapONetRecord) {
        delegate.sendLowPriority(record)
    }
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

    // Backwards-friendly alias.
    fun featureOrNull(): NetworkInspectorFeature? = feature
}

private const val ResponseBodyDelayMillis = 200L
private const val ResponseBodyStaggerMillis = 25L

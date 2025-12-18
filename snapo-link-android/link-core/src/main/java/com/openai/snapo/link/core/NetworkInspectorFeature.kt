package com.openai.snapo.link.core

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

    private val bufferLock = Mutex()
    private val eventBuffer = EventBuffer(config)

    @Volatile
    private var sink: LinkEventSink? = null

    override suspend fun onClientConnected(sink: LinkEventSink) {
        this.sink = sink
        val deferredBodies = mutableListOf<ResponseReceived>()
        val snapshot = bufferLock.withLock { eventBuffer.snapshot() }
        for (record in snapshot) {
            if (record is ResponseReceived && record.hasBodyPayload()) {
                sink.sendHighPriority(record.withoutBodyPayload())
                deferredBodies.add(record)
            } else {
                sink.sendHighPriority(record)
            }
        }
        scheduleDeferredBodies(sink, deferredBodies)
    }

    override fun onClientDisconnected() {
        sink = null
    }

    suspend fun publish(record: SnapONetRecord) {
        bufferLock.withLock { eventBuffer.append(record) }
        val currentSink = sink ?: return
        when (record) {
            is ResponseReceived -> {
                if (record.hasBodyPayload()) {
                    currentSink.sendHighPriority(record.withoutBodyPayload())
                    scheduleResponseBody(currentSink, record)
                } else {
                    currentSink.sendHighPriority(record)
                }
            }
            else -> currentSink.sendHighPriority(record)
        }
    }

    private fun scheduleDeferredBodies(
        sink: LinkEventSink,
        deferredBodies: List<ResponseReceived>,
    ) {
        deferredBodies.forEachIndexed { index, response ->
            val stagger = ResponseBodyStaggerMillis * index
            scheduleResponseBody(sink, response, ResponseBodyDelayMillis + stagger)
        }
    }

    private fun scheduleResponseBody(
        sink: LinkEventSink,
        record: ResponseReceived,
        initialDelayMs: Long = ResponseBodyDelayMillis,
    ) {
        scope.launch(Dispatchers.IO) {
            try {
                if (initialDelayMs > 0) {
                    delay(initialDelayMs)
                }
                if (this@NetworkInspectorFeature.sink !== sink) return@launch
                sink.sendLowPriority(record)
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

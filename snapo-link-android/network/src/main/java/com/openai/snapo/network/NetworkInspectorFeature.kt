package com.openai.snapo.network

import com.openai.snapo.link.core.CdpError
import com.openai.snapo.link.core.CdpGetRequestPostDataParams
import com.openai.snapo.link.core.CdpGetRequestPostDataResult
import com.openai.snapo.link.core.CdpGetResponseBodyParams
import com.openai.snapo.link.core.CdpGetResponseBodyResult
import com.openai.snapo.link.core.CdpMessage
import com.openai.snapo.link.core.CdpNetworkMethod
import com.openai.snapo.link.core.ClientId
import com.openai.snapo.link.core.EventPriority
import com.openai.snapo.link.core.LinkEventSink
import com.openai.snapo.link.core.Ndjson
import com.openai.snapo.link.core.SnapOLinkFeature
import com.openai.snapo.link.core.SnapOLinkRegistry
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
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
        val snapshot = bufferLock.withLock { eventBuffer.snapshot() }

        val requestUrls = HashMap<String, String>()
        for (record in snapshot) {
            if (record is RequestWillBeSent) {
                requestUrls[record.id] = record.url
            }
            val wireRecord = record.withoutInlineBodyPayloads()
            val requestUrl = when (wireRecord) {
                is ResponseReceived -> requestUrls[wireRecord.id]
                else -> null
            }
            current.send(wireRecord.toCdpMessage(requestUrl = requestUrl), clientId = target)
        }
    }

    override suspend fun onFeatureCommand(clientId: Long, payload: JsonElement) {
        val current = sink ?: return
        val command = runCatching {
            Ndjson.decodeFromJsonElement(CdpMessage.serializer(), payload)
        }.getOrNull() ?: return

        val commandId = command.id ?: return
        val method = command.method ?: return
        val target = ClientId.Specific(clientId)

        when (method) {
            CdpNetworkMethod.GetRequestPostData ->
                handleGetRequestPostDataCommand(
                    sink = current,
                    commandId = commandId,
                    target = target,
                    paramsElement = command.params,
                )

            CdpNetworkMethod.GetResponseBody ->
                handleGetResponseBodyCommand(
                    sink = current,
                    commandId = commandId,
                    target = target,
                    paramsElement = command.params,
                )

            else -> current.sendError(commandId, "Unsupported method: $method", target)
        }
    }

    private suspend fun handleGetRequestPostDataCommand(
        sink: NetworkEventSink,
        commandId: Int,
        target: ClientId,
        paramsElement: JsonElement?,
    ) {
        val params = paramsElement?.let { element ->
            runCatching {
                Ndjson.decodeFromJsonElement(CdpGetRequestPostDataParams.serializer(), element)
            }.getOrNull()
        }
        if (params == null) {
            sink.sendError(commandId, "Missing request parameters", target)
            return
        }

        val postData = findLatestRequest(params.requestId)?.body
        if (postData.isNullOrEmpty()) {
            sink.sendError(commandId, "No request body captured for ${params.requestId}", target)
            return
        }

        sink.sendResult(
            id = commandId,
            result = CdpGetRequestPostDataResult(postData = postData),
            serializer = CdpGetRequestPostDataResult.serializer(),
            clientId = target,
        )
    }

    private suspend fun handleGetResponseBodyCommand(
        sink: NetworkEventSink,
        commandId: Int,
        target: ClientId,
        paramsElement: JsonElement?,
    ) {
        val params = paramsElement?.let { element ->
            runCatching {
                Ndjson.decodeFromJsonElement(CdpGetResponseBodyParams.serializer(), element)
            }.getOrNull()
        }
        if (params == null) {
            sink.sendError(commandId, "Missing response parameters", target)
            return
        }

        val response = findLatestResponse(params.requestId)
        val streamBody = if (response?.body.isNullOrEmpty()) {
            joinSseBody(params.requestId)
        } else {
            null
        }
        val resolvedBody = response?.body ?: streamBody
        if (resolvedBody.isNullOrEmpty()) {
            sink.sendError(commandId, "No response body captured for ${params.requestId}", target)
            return
        }

        sink.sendResult(
            id = commandId,
            result = CdpGetResponseBodyResult(
                body = resolvedBody,
                base64Encoded = response?.bodyEncoding.equals("base64", ignoreCase = true),
            ),
            serializer = CdpGetResponseBodyResult.serializer(),
            clientId = target,
        )
    }

    suspend fun publish(record: NetworkEventRecord) {
        val wireMessage = bufferLock.withLock {
            eventBuffer.append(record)
            val snapshot = eventBuffer.snapshot()
            val wireRecord = record.withoutInlineBodyPayloads()
            val requestUrl = when (wireRecord) {
                is ResponseReceived -> latestRequestUrl(snapshot, wireRecord.id)
                else -> null
            }
            wireRecord.toCdpMessage(requestUrl = requestUrl)
        }
        val currentSink = sink ?: return
        currentSink.send(wireMessage)
    }

    suspend fun updateLatestResponseBody(
        requestId: String,
        bodyPreview: String?,
        body: String?,
        bodyEncoding: String?,
        bodyTruncatedBytes: Long?,
        bodySize: Long?,
    ) {
        bufferLock.withLock {
            eventBuffer.updateLatestResponseBody(
                requestId = requestId,
                bodyPreview = bodyPreview,
                body = body,
                bodyEncoding = bodyEncoding,
                bodyTruncatedBytes = bodyTruncatedBytes,
                bodySize = bodySize,
            )
        }
    }

    private suspend fun findLatestRequest(requestId: String): RequestWillBeSent? {
        val snapshot = bufferLock.withLock { eventBuffer.snapshot() }
        return snapshot.asReversed().firstNotNullOfOrNull { record ->
            (record as? RequestWillBeSent)?.takeIf { it.id == requestId }
        }
    }

    private suspend fun findLatestResponse(requestId: String): ResponseReceived? {
        val snapshot = bufferLock.withLock { eventBuffer.snapshot() }
        return snapshot.asReversed().firstNotNullOfOrNull { record ->
            (record as? ResponseReceived)?.takeIf { it.id == requestId }
        }
    }

    private suspend fun joinSseBody(requestId: String): String? {
        val snapshot = bufferLock.withLock { eventBuffer.snapshot() }
        val events = snapshot
            .filterIsInstance<ResponseStreamEvent>()
            .filter { it.id == requestId }
            .sortedWith(compareBy<ResponseStreamEvent> { it.sequence }.thenBy { it.tWallMs })
        if (events.isEmpty()) return null
        return events.joinToString(separator = "") { event ->
            val normalized = event.raw.replace(Regex("\\n+$"), "")
            "$normalized\n\n"
        }
    }

    private fun latestRequestUrl(snapshot: List<NetworkEventRecord>, requestId: String): String? =
        snapshot.asReversed().firstNotNullOfOrNull { record ->
            (record as? RequestWillBeSent)?.takeIf { it.id == requestId }?.url
        }

    private fun NetworkEventRecord.withoutInlineBodyPayloads(): NetworkEventRecord {
        return when (this) {
            is RequestWillBeSent -> copy(body = null)
            is ResponseReceived -> copy(bodyPreview = null, body = null)
            else -> this
        }
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
}

private class NetworkEventSink(
    private val delegate: LinkEventSink,
) {
    fun send(
        message: CdpMessage,
        clientId: ClientId = ClientId.All,
        priority: EventPriority = EventPriority.High,
    ) {
        delegate.send(message, CdpMessage.serializer(), clientId, priority)
    }

    fun sendError(
        id: Int,
        message: String,
        clientId: ClientId,
    ) {
        send(
            CdpMessage(
                id = id,
                error = CdpError(
                    code = -32000,
                    message = message,
                ),
            ),
            clientId = clientId,
        )
    }

    fun <T> sendResult(
        id: Int,
        result: T,
        serializer: kotlinx.serialization.KSerializer<T>,
        clientId: ClientId,
    ) {
        val payload = Ndjson.encodeToJsonElement(serializer, result)
        send(
            CdpMessage(
                id = id,
                result = payload,
            ),
            clientId = clientId,
        )
    }
}

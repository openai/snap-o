package com.openai.snapo.network

import android.app.Application
import android.content.pm.ApplicationInfo
import android.util.Log
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

data class NetworkInspectorConfig(
    /** Keep only the last this-many milliseconds of events in memory. */
    val bufferWindow: Duration = 5.minutes,

    /** Hard caps to avoid runaway memory. */
    val maxBufferedEvents: Int = 10_000,
    val maxBufferedBytes: Long = 16L * 1024 * 1024,

    /** Label surfaced to clients with app metadata. */
    val modeLabel: String = "safe",

    /** Whether the server is allowed to start in a non-debug build. */
    val allowRelease: Boolean = false,
)

class NetworkInspectorServer internal constructor(
    private val app: Application,
    private val config: NetworkInspectorConfig = NetworkInspectorConfig(),
) {
    private val bufferLock = Mutex()
    private val publishLock = Mutex()
    private val eventBuffer = EventBuffer(config)
    private val transport = NetworkInspectorTransport(
        app = app,
        config = config,
        snapshotProvider = ::snapshotMessages,
        commandHandler = ::handleCommand,
    )

    fun start(): Boolean {
        if (!config.allowRelease &&
            app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0
        ) {
            Log.e(
                TAG,
                "Snap-O Network Inspector detected in a release build. Server will NOT start. " +
                    "Release builds should use a noop artifact instead, " +
                    "or set snapo.allow_release=\"true\" if intentional."
            )
            return false
        }
        return transport.start()
    }

    suspend fun publish(record: NetworkEventRecord) {
        publishLock.withLock {
            val wireMessage = bufferLock.withLock {
                val snapoSequence = eventBuffer.append(record)
                val snapshot = eventBuffer.snapshot()
                val wireRecord = record.withoutInlineBodyPayloads()
                val requestUrl = when (wireRecord) {
                    is ResponseReceived -> latestRequestUrl(snapshot, wireRecord.id)
                    else -> null
                }
                wireRecord.toCdpMessage(requestUrl = requestUrl).copy(
                    snapoSequence = snapoSequence,
                )
            }
            transport.broadcast(wireMessage)
        }
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

    private suspend fun snapshotMessages(): NetworkReplaySnapshot {
        val snapshot = bufferLock.withLock { eventBuffer.sequencedSnapshot() }
        val requestUrls = HashMap<String, String>()
        val messages = snapshot.records
            .sortedBy(SequencedNetworkEvent::snapoSequence)
            .map { sequencedRecord ->
                val record = sequencedRecord.record
                if (record is RequestWillBeSent) {
                    requestUrls[record.id] = record.url
                }
                val wireRecord = record.withoutInlineBodyPayloads()
                val requestUrl = when (wireRecord) {
                    is ResponseReceived -> requestUrls[wireRecord.id]
                    else -> null
                }
                wireRecord.toCdpMessage(requestUrl = requestUrl).copy(
                    snapoSequence = sequencedRecord.snapoSequence,
                )
            }
        return NetworkReplaySnapshot(
            messages = messages,
            watermark = snapshot.watermark,
        )
    }

    private suspend fun handleCommand(message: CdpMessage): CdpMessage? {
        val commandId = message.id ?: return null
        val method = message.method ?: return null

        return when (method) {
            CdpNetworkMethod.GetRequestPostData ->
                handleGetRequestPostDataCommand(commandId, message.params)

            CdpNetworkMethod.GetResponseBody ->
                handleGetResponseBodyCommand(commandId, message.params)

            else -> errorResponse(commandId, "Unsupported method: $method")
        }
    }

    private suspend fun handleGetRequestPostDataCommand(
        commandId: Int,
        paramsElement: JsonElement?,
    ): CdpMessage {
        val params = paramsElement?.let { element ->
            runCatching {
                ProtocolJson.decodeFromJsonElement(
                    CdpGetRequestPostDataParams.serializer(),
                    element,
                )
            }.getOrNull()
        }
        if (params == null) {
            return errorResponse(commandId, "Missing request parameters")
        }

        val postData = bufferLock.withLock {
            eventBuffer.findRequestBody(params.requestId)?.body
        }
        if (postData.isNullOrEmpty()) {
            return errorResponse(commandId, "No request body captured for ${params.requestId}")
        }

        return resultResponse(
            id = commandId,
            result = CdpGetRequestPostDataResult(postData = postData),
            serializer = CdpGetRequestPostDataResult.serializer(),
        )
    }

    private suspend fun handleGetResponseBodyCommand(
        commandId: Int,
        paramsElement: JsonElement?,
    ): CdpMessage {
        val params = paramsElement?.let { element ->
            runCatching {
                ProtocolJson.decodeFromJsonElement(
                    CdpGetResponseBodyParams.serializer(),
                    element,
                )
            }.getOrNull()
        }
        if (params == null) {
            return errorResponse(commandId, "Missing response parameters")
        }

        val responseBody = bufferLock.withLock {
            eventBuffer.findResponseBody(params.requestId)
        }
        val streamBody = if (responseBody?.body.isNullOrEmpty()) {
            joinSseBody(params.requestId)
        } else {
            null
        }
        val resolvedBody = responseBody?.body ?: streamBody
        if (resolvedBody.isNullOrEmpty()) {
            return errorResponse(commandId, "No response body captured for ${params.requestId}")
        }

        return resultResponse(
            id = commandId,
            result = CdpGetResponseBodyResult(
                body = resolvedBody,
                base64Encoded = responseBody?.encoding.equals("base64", ignoreCase = true),
            ),
            serializer = CdpGetResponseBodyResult.serializer(),
        )
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

    private fun errorResponse(id: Int, message: String): CdpMessage =
        CdpMessage(
            id = id,
            error = CdpError(
                code = -32000,
                message = message,
            ),
        )

    private fun <T> resultResponse(
        id: Int,
        result: T,
        serializer: KSerializer<T>,
    ): CdpMessage =
        CdpMessage(
            id = id,
            result = ProtocolJson.encodeToJsonElement(serializer, result),
        )
}

object NetworkInspector {
    @Volatile
    private var server: NetworkInspectorServer? = null

    /** Create and start the network inspector server; idempotent per process. */
    fun initialize(
        application: Application,
        config: NetworkInspectorConfig = NetworkInspectorConfig(),
    ): NetworkInspectorServer? {
        server?.let { return it }
        return synchronized(this) {
            server ?: NetworkInspectorServer(application, config)
                .takeIf { it.start() }
                ?.also { server = it }
        }
    }

    /** Return the active server, or null if the network inspector is disabled. */
    fun getOrNull(): NetworkInspectorServer? = server
}

private const val TAG = "SnapONetwork"

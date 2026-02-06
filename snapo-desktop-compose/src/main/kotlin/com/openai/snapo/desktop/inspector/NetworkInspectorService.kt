package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.adb.AdbExec
import com.openai.snapo.desktop.adb.DeviceTracker
import com.openai.snapo.desktop.di.AppScope
import com.openai.snapo.desktop.protocol.CdpGetRequestPostDataParams
import com.openai.snapo.desktop.protocol.CdpGetRequestPostDataResult
import com.openai.snapo.desktop.protocol.CdpGetResponseBodyParams
import com.openai.snapo.desktop.protocol.CdpGetResponseBodyResult
import com.openai.snapo.desktop.protocol.CdpMessage
import com.openai.snapo.desktop.protocol.CdpNetworkMethod
import com.openai.snapo.desktop.protocol.Ndjson
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

@SingleIn(AppScope::class)
@Inject
class NetworkInspectorService(
    private val adb: AdbExec,
    private val deviceTracker: DeviceTracker,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private var isStarted: Boolean = false

    private val requestStore = RequestEventStore()
    private val webSocketStore = WebSocketEventStore()

    private val translatorMutex = Mutex()
    private val translatorsByServer = HashMap<SnapOLinkServerId, CdpNetworkMessageTranslator>()

    private val commandMutex = Mutex()
    private var nextCommandId: Int = 1
    private val pendingBodyCommands = HashMap<Int, PendingBodyCommand>()
    private val inFlightBodyRequests = HashSet<BodyCommandKey>()

    private val serverRegistry: SnapOLinkServerRegistry

    private val deviceSocketMonitor: DeviceSocketMonitor

    val servers: StateFlow<List<SnapOLinkServer>>
        get() = serverRegistry.servers

    val requests: StateFlow<List<NetworkInspectorRequest>>
        get() = requestStore.requests

    val webSockets: StateFlow<List<NetworkInspectorWebSocket>>
        get() = webSocketStore.webSockets

    init {
        serverRegistry = SnapOLinkServerRegistry(
            adb = adb,
            scope = scope,
            onNetworkEvent = { serverId, payload -> handleNetworkEvent(serverId, payload) },
            onServerRemoved = { serverId -> handleServerRemoved(serverId) },
            onSocketStale = { deviceId, socketName -> deviceSocketMonitor.forgetSocket(deviceId, socketName) },
        )

        deviceSocketMonitor = DeviceSocketMonitor(
            adb = adb,
            deviceTracker = deviceTracker,
            scope = scope,
            callbacks = DeviceSocketMonitorCallbacks(
                onDevicesUpdated = { devices -> serverRegistry.updateDevices(devices) },
                onSocketAdded = { deviceId, socketName -> serverRegistry.startServerConnection(deviceId, socketName) },
                onSocketRemoved = { deviceId, socketName -> serverRegistry.stopServerConnection(deviceId, socketName) },
                onDeviceDisconnected = { deviceId -> serverRegistry.removeServersForDevice(deviceId) },
            ),
        )
    }

    fun start() {
        if (isStarted) return
        isStarted = true
        deviceSocketMonitor.start()
    }

    fun stop() {
        deviceSocketMonitor.stop()
        scope.launch {
            serverRegistry.shutdown()
        }
    }

    suspend fun updateRetainedServers(ids: Set<SnapOLinkServerId>) {
        serverRegistry.updateRetainedServers(ids)
    }

    fun sendFeatureOpened(feature: String, serverId: SnapOLinkServerId?) {
        scope.launch {
            serverRegistry.sendFeatureOpened(feature, serverId)
        }
    }

    fun requestBodiesForRequest(id: NetworkInspectorRequestId) {
        scope.launch {
            requestBodyIfNeeded(id)
            responseBodyIfNeeded(id)
        }
    }

    suspend fun clearCompletedEntries() {
        requestStore.clearCompletedEntries()
        webSocketStore.clearCompletedEntries()
    }

    private suspend fun requestBodyIfNeeded(id: NetworkInspectorRequestId) {
        if (!requestStore.shouldRequestRequestBody(id)) return
        sendBodyCommandIfNeeded(
            key = BodyCommandKey(id, BodyCommandType.Request),
            method = CdpNetworkMethod.GetRequestPostData,
            params = Ndjson.encodeToJsonElement(
                CdpGetRequestPostDataParams.serializer(),
                CdpGetRequestPostDataParams(requestId = id.requestId),
            ),
        )
    }

    private suspend fun responseBodyIfNeeded(id: NetworkInspectorRequestId) {
        if (!requestStore.shouldRequestResponseBody(id)) return
        sendBodyCommandIfNeeded(
            key = BodyCommandKey(id, BodyCommandType.Response),
            method = CdpNetworkMethod.GetResponseBody,
            params = Ndjson.encodeToJsonElement(
                CdpGetResponseBodyParams.serializer(),
                CdpGetResponseBodyParams(requestId = id.requestId),
            ),
        )
    }

    private suspend fun sendBodyCommandIfNeeded(
        key: BodyCommandKey,
        method: String,
        params: kotlinx.serialization.json.JsonElement,
    ) {
        var commandId: Int? = null
        commandMutex.withLock {
            if (!inFlightBodyRequests.add(key)) return@withLock
            val id = nextCommandId
            nextCommandId += 1
            pendingBodyCommands[id] = PendingBodyCommand(key = key, method = method)
            commandId = id
        }
        val resolvedCommandId = commandId ?: return

        val message = CdpMessage(
            id = resolvedCommandId,
            method = method,
            params = params,
        )
        val payload = Ndjson.encodeToJsonElement(CdpMessage.serializer(), message)
        runCatching {
            serverRegistry.sendFeatureCommand(
                feature = NetworkFeatureId,
                payload = payload,
                serverId = key.requestId.serverId,
            )
        }.onFailure {
            commandMutex.withLock {
                pendingBodyCommands.remove(resolvedCommandId)
                inFlightBodyRequests.remove(key)
            }
        }
    }

    private suspend fun handleNetworkEvent(serverId: SnapOLinkServerId, payload: CdpMessage) {
        if (handleCommandResponse(serverId, payload)) return

        val translator = translatorMutex.withLock {
            translatorsByServer.getOrPut(serverId) { CdpNetworkMessageTranslator() }
        }
        val event = translator.toRecord(payload) ?: return

        if (requestStore.handle(serverId, event)) return
        webSocketStore.handle(serverId, event)
    }

    private suspend fun handleCommandResponse(serverId: SnapOLinkServerId, payload: CdpMessage): Boolean {
        val commandId = payload.id ?: return false
        if (payload.method != null) return false

        var pending: PendingBodyCommand? = null
        commandMutex.withLock {
            val removed = pendingBodyCommands.remove(commandId)
            if (removed != null) {
                inFlightBodyRequests.remove(removed.key)
                pending = removed
            }
        }
        val resolvedPending = pending ?: return true
        if (resolvedPending.key.requestId.serverId != serverId) return true
        if (payload.error != null) return true

        when (resolvedPending.method) {
            CdpNetworkMethod.GetRequestPostData -> {
                val result = payload.result
                    ?.let { element ->
                        runCatching {
                            Ndjson.decodeFromJsonElement(CdpGetRequestPostDataResult.serializer(), element)
                        }.getOrNull()
                    } ?: return true
                requestStore.applyRequestBody(
                    id = resolvedPending.key.requestId,
                    body = result.postData,
                )
            }

            CdpNetworkMethod.GetResponseBody -> {
                val result = payload.result
                    ?.let { element ->
                        runCatching {
                            Ndjson.decodeFromJsonElement(CdpGetResponseBodyResult.serializer(), element)
                        }.getOrNull()
                    } ?: return true
                requestStore.applyResponseBody(
                    id = resolvedPending.key.requestId,
                    body = result.body,
                    base64Encoded = result.base64Encoded,
                )
            }
        }

        return true
    }

    private suspend fun handleServerRemoved(serverId: SnapOLinkServerId) {
        requestStore.removeServer(serverId)
        webSocketStore.removeServer(serverId)

        translatorMutex.withLock {
            translatorsByServer.remove(serverId)
        }

        commandMutex.withLock {
            val idsToRemove = pendingBodyCommands
                .filterValues { pending -> pending.key.requestId.serverId == serverId }
                .keys
                .toList()
            idsToRemove.forEach { pendingBodyCommands.remove(it) }
            inFlightBodyRequests.removeAll { key -> key.requestId.serverId == serverId }
        }
    }
}

private const val NetworkFeatureId: String = "network"

private enum class BodyCommandType {
    Request,
    Response,
}

private data class BodyCommandKey(
    val requestId: NetworkInspectorRequestId,
    val type: BodyCommandType,
)

private data class PendingBodyCommand(
    val key: BodyCommandKey,
    val method: String,
)

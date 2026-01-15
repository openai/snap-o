package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.adb.AdbExec
import com.openai.snapo.desktop.adb.DeviceTracker
import com.openai.snapo.desktop.di.AppScope
import com.openai.snapo.desktop.protocol.SnapONetRecord
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

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

    suspend fun clearCompletedEntries() {
        requestStore.clearCompletedEntries()
        webSocketStore.clearCompletedEntries()
    }

    private suspend fun handleNetworkEvent(serverId: SnapOLinkServerId, payload: SnapONetRecord) {
        if (requestStore.handle(serverId, payload)) return
        webSocketStore.handle(serverId, payload)
    }

    private suspend fun handleServerRemoved(serverId: SnapOLinkServerId) {
        requestStore.removeServer(serverId)
        webSocketStore.removeServer(serverId)
    }
}

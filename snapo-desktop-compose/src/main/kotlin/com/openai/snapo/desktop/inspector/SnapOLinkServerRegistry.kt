package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.adb.AdbExec
import com.openai.snapo.desktop.adb.AdbForwardHandle
import com.openai.snapo.desktop.adb.Device
import com.openai.snapo.desktop.link.SnapOLinkServerConnection
import com.openai.snapo.desktop.link.SnapORecord
import com.openai.snapo.desktop.protocol.CdpMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import java.time.Instant

internal class SnapOLinkServerRegistry(
    private val adb: AdbExec,
    private val scope: CoroutineScope,
    private val onNetworkEvent: suspend (SnapOLinkServerId, CdpMessage) -> Unit,
    private val onServerRemoved: suspend (SnapOLinkServerId) -> Unit,
    private val onSocketStale: suspend (String, String) -> Unit,
) {
    private data class ServerState(
        val server: SnapOLinkServer,
        val forwardHandle: AdbForwardHandle?,
        val connection: SnapOLinkServerConnection?,
    )

    private val mutex = Mutex()
    private val serverStates = HashMap<SnapOLinkServerId, ServerState>()
    private var retainedServerIds: Set<SnapOLinkServerId> = emptySet()
    private var devices: Map<String, Device> = emptyMap()

    private val _servers = MutableStateFlow<List<SnapOLinkServer>>(emptyList())
    val servers: StateFlow<List<SnapOLinkServer>> = _servers.asStateFlow()

    suspend fun updateDevices(latest: Map<String, Device>) {
        val updates = ArrayList<Pair<SnapOLinkServerId, SnapOLinkServer>>()
        mutex.withLock {
            devices = latest
            serverStates.forEach { (id, state) ->
                val newTitle = devices[id.deviceId]?.displayTitle ?: id.deviceId
                if (state.server.deviceDisplayTitle != newTitle) {
                    updates.add(id to state.server.copy(deviceDisplayTitle = newTitle))
                }
            }
            if (updates.isNotEmpty()) {
                for ((id, updatedServer) in updates) {
                    val state = serverStates[id] ?: continue
                    serverStates[id] = state.copy(server = updatedServer)
                }
                broadcastServersLocked()
            }
        }
    }

    suspend fun startServerConnection(deviceId: String, socketName: String) {
        val handle = try {
            adb.forwardLocalAbstract(deviceId, socketName)
        } catch (_: Throwable) {
            onSocketStale(deviceId, socketName)
            return
        }

        val serverId = SnapOLinkServerId(deviceId = deviceId, socketName = socketName)
        val existing = mutex.withLock { serverStates[serverId]?.server }
        val deviceTitle = mutex.withLock { devices[deviceId]?.displayTitle } ?: deviceId

        val server = SnapOLinkServer(
            deviceId = deviceId,
            socketName = socketName,
            localPort = handle.localPort,
            hello = existing?.hello,
            schemaVersion = existing?.schemaVersion,
            isSchemaNewerThanSupported = existing?.isSchemaNewerThanSupported ?: false,
            isSchemaOlderThanSupported = existing?.isSchemaOlderThanSupported ?: false,
            lastEventAt = existing?.lastEventAt,
            deviceDisplayTitle = deviceTitle,
            isConnected = true,
            appIcon = existing?.appIcon,
            packageNameHint = existing?.packageNameHint,
            features = existing?.features ?: emptySet(),
        )

        val connection = SnapOLinkServerConnection(
            port = handle.localPort,
            onEvent = { record ->
                scope.launch { handleRecord(record, from = serverId) }
            },
            onClose = { _ ->
                scope.launch { connectionClosed(serverId) }
            },
        )

        mutex.withLock {
            serverStates[serverId] = ServerState(server = server, forwardHandle = handle, connection = connection)
            broadcastServersLocked()
        }

        connection.start()

        if (server.hello == null && server.packageNameHint.isNullOrBlank()) {
            populatePackageNameHint(serverId, deviceId, socketName)
        }
    }

    suspend fun stopServerConnection(deviceId: String, socketName: String) {
        val serverId = SnapOLinkServerId(deviceId = deviceId, socketName = socketName)
        removeServer(serverId)
    }

    suspend fun removeServersForDevice(deviceId: String) {
        val ids = mutex.withLock {
            serverStates.keys.filter { it.deviceId == deviceId }
        }
        for (id in ids) {
            removeServer(id)
        }
    }

    suspend fun updateRetainedServers(ids: Set<SnapOLinkServerId>) {
        mutex.withLock {
            retainedServerIds = ids
        }
        purgeUnretainedDisconnectedServers()
    }

    suspend fun sendFeatureOpened(feature: String, serverId: SnapOLinkServerId?) {
        val connection = mutex.withLock {
            val target = serverId
                ?: serverStates.entries.firstOrNull { it.value.server.isConnected }?.key
                ?: return@withLock null
            serverStates[target]?.connection
        } ?: return

        connection.sendFeatureOpened(feature)
    }

    suspend fun sendFeatureCommand(
        feature: String,
        payload: JsonElement,
        serverId: SnapOLinkServerId,
    ): Boolean {
        val connection = mutex.withLock { serverStates[serverId]?.connection } ?: return false
        connection.sendFeatureCommand(feature = feature, payload = payload)
        return true
    }

    suspend fun shutdown() {
        val states = mutex.withLock { serverStates.values.toList() }
        for (state in states) {
            try {
                state.connection?.stop()
            } catch (_: Throwable) {
            }
            try {
                state.forwardHandle?.let { adb.removeForward(it) }
            } catch (_: Throwable) {
            }
        }
    }

    private suspend fun populatePackageNameHint(serverId: SnapOLinkServerId, deviceId: String, socketName: String) {
        val pid = pidFromSocketName(socketName) ?: return
        val output = try {
            adb.runShellString(deviceId, "cat /proc/$pid/cmdline 2>/dev/null")
        } catch (_: Throwable) {
            return
        }

        val candidate = output
            .split('\u0000')
            .firstOrNull { it.isNotBlank() }
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?: output.lineSequence().firstOrNull()?.trim()?.takeIf { it.isNotBlank() }

        if (candidate.isNullOrBlank()) return

        mutex.withLock {
            val state = serverStates[serverId] ?: return@withLock
            if (state.server.packageNameHint == candidate) return@withLock
            serverStates[serverId] = state.copy(server = state.server.copy(packageNameHint = candidate))
            broadcastServersLocked()
        }
    }

    private fun pidFromSocketName(socketName: String): Int? {
        val prefix = "snapo_server_"
        if (!socketName.startsWith(prefix)) return null
        val suffix = socketName.removePrefix(prefix)
        if (suffix.isBlank() || suffix.any { !it.isDigit() }) return null
        return suffix.toIntOrNull()
    }

    private suspend fun removeServer(id: SnapOLinkServerId, force: Boolean = false) {
        val (state, shouldRetain) = mutex.withLock {
            val state = serverStates[id] ?: return@withLock null
            val retain = !force && retainedServerIds.contains(id)
            state to retain
        } ?: return

        try {
            state.connection?.stop()
        } catch (_: Throwable) {
        }

        try {
            state.forwardHandle?.let { adb.removeForward(it) }
        } catch (_: Throwable) {
        }

        onSocketStale(id.deviceId, id.socketName)

        val removed = mutex.withLock {
            if (shouldRetain) {
                serverStates[id] = state.copy(
                    server = state.server.copy(isConnected = false),
                    forwardHandle = null,
                    connection = null,
                )
                broadcastServersLocked()
                false
            } else {
                serverStates.remove(id)
                broadcastServersLocked()
                true
            }
        }

        if (removed) {
            onServerRemoved(id)
        }
    }

    private suspend fun connectionClosed(serverId: SnapOLinkServerId) {
        removeServer(serverId)
    }

    private suspend fun handleRecord(record: SnapORecord, from: SnapOLinkServerId) {
        val now = Instant.now()

        when (record) {
            is SnapORecord.HelloRecord -> handleHelloRecord(from, record, now)
            is SnapORecord.AppIconRecord -> handleAppIconRecord(from, record, now)
            is SnapORecord.NetworkEvent -> handleNetworkEvent(from, record.value, now)

            SnapORecord.ReplayComplete -> Unit

            is SnapORecord.Unknown -> Unit
        }
    }

    private suspend fun handleHelloRecord(
        serverId: SnapOLinkServerId,
        record: SnapORecord.HelloRecord,
        now: Instant,
    ) {
        mutex.withLock {
            val state = serverStates[serverId] ?: return@withLock
            val hello = record.value
            val features = hello.features.map { it.id }.toSet()
            val schemaVersion = hello.schemaVersion
            val updated = state.server.copy(
                hello = hello,
                schemaVersion = schemaVersion,
                isSchemaNewerThanSupported = schemaVersion?.let { it > SupportedSchemaVersion } == true,
                isSchemaOlderThanSupported = schemaVersion == null || schemaVersion < SupportedSchemaVersion,
                features = features,
                lastEventAt = now,
            )
            serverStates[serverId] = state.copy(server = updated)
            broadcastServersLocked()
        }
    }

    private suspend fun handleAppIconRecord(
        serverId: SnapOLinkServerId,
        record: SnapORecord.AppIconRecord,
        now: Instant,
    ) {
        mutex.withLock {
            val state = serverStates[serverId] ?: return@withLock
            val icon = record.value
            val currentPackage = state.server.hello?.packageName
            if (currentPackage != null && currentPackage != icon.packageName) return@withLock
            if (state.server.appIcon?.base64Data == icon.base64Data) return@withLock
            val updated = state.server.copy(appIcon = icon, lastEventAt = now)
            serverStates[serverId] = state.copy(server = updated)
            broadcastServersLocked()
        }
    }

    private suspend fun handleNetworkEvent(
        serverId: SnapOLinkServerId,
        payload: CdpMessage,
        now: Instant,
    ) {
        val shouldHandle = mutex.withLock {
            val state = serverStates[serverId] ?: return@withLock false
            serverStates[serverId] = state.copy(server = state.server.copy(lastEventAt = now))
            true
        }
        if (shouldHandle) {
            onNetworkEvent(serverId, payload)
        }
    }

    private suspend fun purgeUnretainedDisconnectedServers() {
        val toRemove = mutex.withLock {
            serverStates.filter { (id, state) ->
                !retainedServerIds.contains(id) && !state.server.isConnected
            }.keys.toList()
        }
        for (id in toRemove) {
            removeServer(id, force = true)
        }
    }

    private fun broadcastServersLocked() {
        _servers.value = serverStates.values
            .map { it.server }
            .sortedWith(compareBy<SnapOLinkServer> { it.deviceId }.thenBy { it.socketName })
    }
}

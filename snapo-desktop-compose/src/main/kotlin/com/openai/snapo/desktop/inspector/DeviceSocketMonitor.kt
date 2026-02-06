package com.openai.snapo.desktop.inspector

import com.openai.snapo.desktop.adb.AdbExec
import com.openai.snapo.desktop.adb.Device
import com.openai.snapo.desktop.adb.DeviceTracker
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal data class DeviceSocketMonitorCallbacks(
    val onDevicesUpdated: suspend (Map<String, Device>) -> Unit,
    val onSocketAdded: suspend (String, String) -> Unit,
    val onSocketRemoved: suspend (String, String) -> Unit,
    val onDeviceDisconnected: suspend (String) -> Unit,
)

internal class DeviceSocketMonitor(
    private val adb: AdbExec,
    private val deviceTracker: DeviceTracker,
    private val scope: CoroutineScope,
    private val callbacks: DeviceSocketMonitorCallbacks,
) {
    private val mutex = Mutex()
    private var isStarted: Boolean = false
    private var deviceStreamJob: Job? = null
    private val deviceMonitors = HashMap<String, Job>()
    private val deviceSockets = HashMap<String, Set<String>>()

    fun start() {
        if (isStarted) return
        isStarted = true

        scope.launch {
            updateDevices(deviceTracker.latestDevices)
        }

        deviceStreamJob = scope.launch {
            deviceTracker.devices.collect { latest ->
                updateDevices(latest)
            }
        }
    }

    fun stop() {
        deviceStreamJob?.cancel()
        deviceStreamJob = null
        for (job in deviceMonitors.values) job.cancel()
        deviceMonitors.clear()
    }

    suspend fun forgetSocket(deviceId: String, socketName: String) {
        mutex.withLock {
            deviceSockets[deviceId] = (deviceSockets[deviceId] ?: emptySet()).minus(socketName)
        }
    }

    private suspend fun updateDevices(latest: List<Device>) {
        val active = latest.map { it.id }.toSet()
        val newDevices = latest.associateBy { it.id }

        val toStart: List<String>
        val toStop: List<String>

        mutex.withLock {
            val known = deviceMonitors.keys.toSet()
            toStart = active.subtract(known).toList()
            toStop = known.subtract(active).toList()
        }

        callbacks.onDevicesUpdated(newDevices)

        for (deviceId in toStart) {
            startMonitoringDevice(deviceId)
        }
        for (deviceId in toStop) {
            stopMonitoringDevice(deviceId)
        }
    }

    private suspend fun startMonitoringDevice(deviceId: String) {
        val job = mutex.withLock {
            if (deviceMonitors.containsKey(deviceId)) {
                return@withLock null
            }
            scope.launch(Dispatchers.Default, start = kotlinx.coroutines.CoroutineStart.LAZY) {
                while (true) {
                    try {
                        val output = adb.listUnixSockets(deviceId)
                        val sockets = parseServers(output)
                        handleSocketsUpdate(deviceId, sockets)
                    } catch (t: CancellationException) {
                        throw t
                    } catch (_: Throwable) {
                        handleSocketsUpdate(deviceId, emptySet())
                    }
                    delay(2_000)
                }
            }.also { deviceMonitors[deviceId] = it }
        }
        job?.start()
    }

    private suspend fun stopMonitoringDevice(deviceId: String) {
        val job = mutex.withLock { deviceMonitors.remove(deviceId) }
        job?.cancel()
        mutex.withLock { deviceSockets[deviceId] = emptySet() }
        callbacks.onDeviceDisconnected(deviceId)
    }

    private suspend fun handleSocketsUpdate(deviceId: String, sockets: Set<String>) {
        val diff = mutex.withLock {
            val previous = deviceSockets[deviceId] ?: emptySet()
            if (previous == sockets) return@withLock null
            deviceSockets[deviceId] = sockets
            sockets.subtract(previous) to previous.subtract(sockets)
        } ?: return
        val (added, removed) = diff

        for (socket in added) callbacks.onSocketAdded(deviceId, socket)
        for (socket in removed) callbacks.onSocketRemoved(deviceId, socket)
    }

    private fun parseServers(output: String): Set<String> {
        val result = LinkedHashSet<String>()
        for (rawLine in output.lineSequence()) {
            val token = rawLine.trim()
                .takeIf { it.isNotEmpty() }
                ?.split(Regex("\\s+"))
                ?.lastOrNull()
            if (token != null && token.startsWith("@snapo_server_")) {
                result.add(token.removePrefix("@"))
            }
        }
        return result
    }
}

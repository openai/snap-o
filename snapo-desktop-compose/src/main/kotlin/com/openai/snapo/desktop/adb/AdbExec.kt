package com.openai.snapo.desktop.adb

import com.openai.snapo.desktop.di.AppScope
import dev.zacsweers.metro.Inject
import dev.zacsweers.metro.SingleIn
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.withContext
import java.net.ServerSocket
import java.nio.charset.StandardCharsets

@SingleIn(AppScope::class)
@Inject
class AdbExec {
    suspend fun trackDevices(): Flow<String> = channelFlow {
        // The ADB server sends a sequence of length-prefixed payloads until the connection is closed.
        val connection = withContext(Dispatchers.IO) { AdbSocketConnection() }
        try {
            withContext(Dispatchers.IO) { connection.sendTrackDevices() }
            while (true) {
                val payload = withContext(Dispatchers.IO) { connection.readLengthPrefixedPayload() } ?: break
                val text = payload.toString(StandardCharsets.UTF_8)
                trySend(text)
            }
        } finally {
            try {
                connection.close()
            } catch (_: Throwable) {
            }
        }
    }

    suspend fun devicesList(): String = withContext(Dispatchers.IO) {
        AdbSocketConnection().use { connection ->
            connection.sendDevicesList()
            val payload = connection.readLengthPrefixedPayload() ?: return@use ""
            payload.toString(StandardCharsets.UTF_8)
        }
    }

    suspend fun runShellString(deviceId: String, command: String): String = withContext(Dispatchers.IO) {
        AdbSocketConnection().use { connection ->
            connection.sendTransport(deviceId)
            connection.sendShell(command)
            val bytes = connection.readToEnd()
            bytes.toString(StandardCharsets.UTF_8)
        }
    }

    suspend fun listUnixSockets(deviceId: String): String =
        runShellString(deviceId, "cat /proc/net/unix")

    suspend fun getProperties(deviceId: String, prefix: String? = null): Map<String, String> {
        val output = runShellString(deviceId, "getprop")
        val result = LinkedHashMap<String, String>()
        for (line in output.lineSequence()) {
            val parsed = parsePropertyLine(line) ?: continue
            if (prefix == null || parsed.first.startsWith(prefix)) {
                result[parsed.first] = parsed.second
            }
        }
        return result
    }

    suspend fun forwardLocalAbstract(deviceId: String, abstractSocket: String): AdbForwardHandle =
        withContext(Dispatchers.IO) {
            AdbSocketConnection().use { connection ->
                val port = allocateEphemeralPort()
                val remote = "localabstract:$abstractSocket"
                connection.sendHostCommand(
                    command = "host-serial:$deviceId:forward:tcp:$port;$remote",
                    expectsResponse = false,
                )
                AdbForwardHandle(
                    deviceId = deviceId,
                    localPort = port,
                    remote = remote,
                )
            }
        }

    suspend fun removeForward(handle: AdbForwardHandle) {
        withContext(Dispatchers.IO) {
            AdbSocketConnection().use { connection ->
                try {
                    connection.sendHostCommand(
                        command = "host-serial:${handle.deviceId}:killforward:tcp:${handle.localPort}",
                        expectsResponse = false,
                    )
                } catch (_: Throwable) {
                    // Best-effort cleanup.
                }
            }
        }
    }

    private fun parsePropertyLine(line: String): Pair<String, String>? {
        // Format: [ro.foo]: [bar]
        val trimmed = line.trim()
        if (trimmed.isEmpty()) return null
        if (!trimmed.startsWith('[')) return null
        val keyEnd = trimmed.indexOf("]:")
        if (keyEnd <= 1) return null
        val key = trimmed.substring(1, keyEnd)

        val valueStart = trimmed.indexOf('[', startIndex = keyEnd + 2)
        val valueEnd = trimmed.lastIndexOf(']')
        if (valueStart == -1 || valueEnd <= valueStart) return null
        val value = trimmed.substring(valueStart + 1, valueEnd)
        return key to value
    }

    private fun allocateEphemeralPort(): Int {
        // Bind to port 0 and let the OS choose an available port.
        // There is a tiny race between releasing this port and adb binding, but it's acceptable.
        ServerSocket(0).use { socket ->
            socket.reuseAddress = true
            return socket.localPort
        }
    }
}

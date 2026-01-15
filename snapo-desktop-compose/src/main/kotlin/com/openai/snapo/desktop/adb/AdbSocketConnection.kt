package com.openai.snapo.desktop.adb

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets

/**
 * Minimal ADB server client speaking the host protocol over TCP (default 127.0.0.1:5037).
 *
 * This is intentionally small and focused: just enough to power the Network Inspector.
 */
internal class AdbSocketConnection(
    host: String = "127.0.0.1",
    port: Int = 5037,
) : AutoCloseable {

    private val socket: Socket = Socket().apply {
        try {
            tcpNoDelay = true
        } catch (_: Throwable) {
        }
        val timeoutMs = 1_000
        connect(InetSocketAddress(host, port), timeoutMs)
    }

    private val input = BufferedInputStream(socket.getInputStream())
    private val output = BufferedOutputStream(socket.getOutputStream())

    override fun close() {
        try {
            socket.close()
        } catch (_: Throwable) {
        }
    }

    fun sendTrackDevices() = sendRequest("host:track-devices-l")

    fun sendDevicesList() = sendRequest("host:devices-l")

    fun sendTransport(deviceId: String) = sendRequest("host:transport:$deviceId")

    fun sendShell(command: String) = sendRequest("shell:$command")

    fun sendHostCommand(command: String, expectsResponse: Boolean): String? {
        sendRequest(command)
        if (!expectsResponse) return null
        val payload = readLengthPrefixedPayload() ?: return null
        return payload.toString(StandardCharsets.UTF_8)
    }

    private fun sendRequest(request: String) {
        val payload = request.toByteArray(StandardCharsets.UTF_8)
        val header = "%04X".format(payload.size).toByteArray(StandardCharsets.US_ASCII)
        writeFully(header)
        writeFully(payload)
        output.flush()
        expectOkay()
    }

    private fun expectOkay() {
        val status = readExact(4).toString(StandardCharsets.US_ASCII)
        if (status == "OKAY") return
        if (status == "FAIL") {
            val errorLen = readLengthPrefix()
            val message = readExact(errorLen).toString(StandardCharsets.UTF_8)
            throw AdbException.ProtocolFailure(message)
        }
        throw AdbException.ProtocolFailure("Unexpected adb status: $status")
    }

    fun readLengthPrefixedPayload(): ByteArray? {
        val len = readLengthPrefixOrNull() ?: return null
        if (len > MaxAdbPayloadBytes) {
            throw AdbException.ProtocolFailure("ADB payload too large: $len bytes")
        }
        if (len == 0) return ByteArray(0)
        return readExact(len)
    }

    fun readToEnd(): ByteArray {
        val buffer = ByteArray(64 * 1024)
        val out = ByteArrayOutputStream(64 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private fun readLengthPrefix(): Int {
        val header = readExact(4).toString(StandardCharsets.US_ASCII)
        return header.toInt(16)
    }

    private fun readLengthPrefixOrNull(): Int? {
        val header = readExactOrNull(4) ?: return null
        return header.toString(StandardCharsets.US_ASCII).toInt(16)
    }

    private fun readExact(byteCount: Int): ByteArray {
        return readExactOrNull(byteCount)
            ?: throw AdbException.ProtocolFailure("Unexpected end of stream while reading $byteCount bytes")
    }

    private fun readExactOrNull(byteCount: Int): ByteArray? {
        val out = ByteArray(byteCount)
        var offset = 0
        while (offset < byteCount) {
            val read = input.read(out, offset, byteCount - offset)
            if (read == -1) {
                return if (offset == 0) null else null
            }
            offset += read
        }
        return out
    }

    private fun writeFully(bytes: ByteArray) {
        try {
            output.write(bytes)
        } catch (t: IOException) {
            throw AdbException.ServerUnavailable("Failed writing to adb server", t)
        }
    }
}

private const val MaxAdbPayloadBytes: Int = 1 * 1024 * 1024

package com.openai.snapo.desktop.link

import com.openai.snapo.desktop.protocol.FeatureCommand
import com.openai.snapo.desktop.protocol.FeatureOpened
import com.openai.snapo.desktop.protocol.HostMessage
import com.openai.snapo.desktop.protocol.Ndjson
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.JsonElement
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets

class SnapOLinkServerConnection(
    private val port: Int,
    private val onEvent: (SnapORecord) -> Unit,
    private val onClose: (Throwable?) -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null

    @Volatile
    private var socket: Socket? = null

    @Volatile
    private var output: BufferedOutputStream? = null

    fun start() {
        if (job != null) return
        job = scope.launch {
            runConnection()
        }
    }

    fun stop() {
        scope.cancel()
        closeSocket()
    }

    fun sendFeatureOpened(feature: String) {
        // Fire-and-forget: the UI may call this frequently (e.g., focus changes).
        scope.launch {
            sendHostMessage(FeatureOpened(feature))
        }
    }

    fun sendFeatureCommand(feature: String, payload: JsonElement) {
        scope.launch {
            sendHostMessage(FeatureCommand(feature = feature, payload = payload))
        }
    }

    private suspend fun sendHostMessage(message: HostMessage) {
        val writer = output
        if (writer == null) return
        val line = Ndjson.encodeToString(HostMessage.serializer(), message) + "\n"
        val bytes = line.toByteArray(StandardCharsets.UTF_8)
        withContext(Dispatchers.IO) {
            synchronized(writer) {
                writer.write(bytes)
                writer.flush()
            }
        }
    }

    private suspend fun runConnection() {
        try {
            val socket = Socket()
            socket.tcpNoDelay = true
            val timeoutMs = 1_000
            socket.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
            this.socket = socket

            val input = BufferedInputStream(socket.getInputStream())
            val output = BufferedOutputStream(socket.getOutputStream())
            this.output = output

            // Handshake required by the Android server.
            output.write("HelloSnapO\n".toByteArray(StandardCharsets.UTF_8))
            output.flush()

            readIncomingStream(input)

            onClose(null)
        } catch (t: CancellationException) {
            throw t
        } catch (t: IOException) {
            onClose(t)
        } catch (t: SecurityException) {
            onClose(t)
        } finally {
            closeSocket()
        }
    }

    private fun readIncomingStream(input: BufferedInputStream) {
        val readBuffer = ByteArray(64 * 1024)
        val lineBuffer = ByteArrayOutputStream(8 * 1024)
        var skippingOversizedLine = false

        while (true) {
            val read = input.read(readBuffer)
            if (read <= 0) break
            skippingOversizedLine = appendLines(readBuffer, read, lineBuffer, skippingOversizedLine)
        }

        if (!skippingOversizedLine) {
            flushLineBuffer(lineBuffer)
        }
    }

    private fun appendLines(
        buffer: ByteArray,
        read: Int,
        lineBuffer: ByteArrayOutputStream,
        skippingOversizedLine: Boolean,
    ): Boolean {
        var skipping = skippingOversizedLine
        for (i in 0 until read) {
            skipping = processByte(buffer[i], lineBuffer, skipping)
        }
        return skipping
    }

    private fun processByte(
        value: Byte,
        lineBuffer: ByteArrayOutputStream,
        skippingOversizedLine: Boolean,
    ): Boolean {
        return when (value) {
            '\n'.code.toByte() -> {
                if (!skippingOversizedLine) {
                    dispatchLine(lineBuffer)
                }
                lineBuffer.reset()
                false
            }
            '\r'.code.toByte() -> skippingOversizedLine
            else -> appendByte(lineBuffer, skippingOversizedLine, value)
        }
    }

    private fun appendByte(
        lineBuffer: ByteArrayOutputStream,
        skippingOversizedLine: Boolean,
        value: Byte,
    ): Boolean {
        if (skippingOversizedLine) return true
        if (lineBuffer.size() < MaxNdjsonLineBytes) {
            lineBuffer.write(value.toInt())
            return false
        }
        // Drop oversized lines to avoid unbounded memory use.
        lineBuffer.reset()
        return true
    }

    private fun flushLineBuffer(lineBuffer: ByteArrayOutputStream) {
        if (lineBuffer.size() == 0) return
        dispatchLine(lineBuffer)
    }

    private fun dispatchLine(lineBuffer: ByteArrayOutputStream) {
        val line = lineBuffer.toString(StandardCharsets.UTF_8.name())
        if (line.isNotBlank()) {
            try {
                onEvent(SnapORecordDecoder.decodeNdjsonLine(line))
            } catch (error: SerializationException) {
                // Ignore malformed lines; keep the connection alive.
            } catch (error: IllegalArgumentException) {
                // Ignore malformed lines; keep the connection alive.
            }
        }
    }

    private fun closeSocket() {
        try {
            output = null
        } catch (_: Throwable) {
        }
        try {
            socket?.close()
        } catch (_: Throwable) {
        }
        socket = null
    }
}

private const val MaxNdjsonLineBytes: Int = 16 * 1024 * 1024

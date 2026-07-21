@file:androidx.annotation.RestrictTo(androidx.annotation.RestrictTo.Scope.LIBRARY_GROUP)

package com.openai.snapo.network.capture

import android.os.SystemClock
import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.ResponseStreamClosed
import com.openai.snapo.network.ResponseStreamEvent
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/**
 * Client-neutral SSE decoding and stream state shared by Snap-O's network integrations.
 *
 * Stream reads and publication ordering remain owned by the client-specific adapters.
 */
class SseStreamCapture internal constructor(
    private val requestId: String,
    charset: Charset,
    private val onRecord: (NetworkEventRecord) -> Unit,
    private val wallTimeMillis: () -> Long,
    private val monotonicNanos: () -> Long,
) {
    constructor(
        requestId: String,
        charset: Charset,
        onRecord: (NetworkEventRecord) -> Unit,
    ) : this(
        requestId = requestId,
        charset = charset,
        onRecord = onRecord,
        wallTimeMillis = System::currentTimeMillis,
        monotonicNanos = SystemClock::elapsedRealtimeNanos,
    )

    private val lock = Any()
    private val decoder = charset.newDecoder()
        .onMalformedInput(CodingErrorAction.REPLACE)
        .onUnmappableCharacter(CodingErrorAction.REPLACE)
    private val text = StringBuilder()
    private var undecodedBytes = ByteArray(0)
    private var pendingCarriageReturn = false
    private var totalBytes = 0L
    private var nextSequence = 0L
    private var completed = false

    fun append(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset) {
        require(offset >= 0 && length >= 0 && offset <= bytes.size - length) {
            "offset and length must describe a valid byte range"
        }
        if (length == 0) return
        synchronized(lock) {
            if (completed) return
            totalBytes += length.toLong()
            appendDecoded(decode(bytes, offset, length, endOfInput = false))
            drainEvents(flushTail = false).forEach(::emit)
        }
    }

    fun complete(error: Throwable? = null) {
        synchronized(lock) {
            if (completed) return
            completed = true
            appendDecoded(decode(ByteArray(0), 0, 0, endOfInput = true))
            flushPendingCarriageReturn()
            drainEvents(flushTail = true).forEach(::emit)
            emit(
                ResponseStreamClosed(
                    id = requestId,
                    tWallMs = wallTimeMillis(),
                    tMonoNs = monotonicNanos(),
                    reason = if (error == null) "completed" else "error",
                    message = error?.message ?: error?.javaClass?.simpleName,
                    totalEvents = nextSequence,
                    totalBytes = totalBytes,
                ),
            )
        }
    }

    private fun decode(
        bytes: ByteArray,
        offset: Int,
        length: Int,
        endOfInput: Boolean,
    ): String {
        val input = if (undecodedBytes.isEmpty()) {
            ByteBuffer.wrap(bytes, offset, length)
        } else {
            val combined = ByteArray(undecodedBytes.size + length)
            undecodedBytes.copyInto(combined)
            bytes.copyInto(
                combined,
                destinationOffset = undecodedBytes.size,
                startIndex = offset,
                endIndex = offset + length,
            )
            ByteBuffer.wrap(combined)
        }
        val decoded = StringBuilder()
        val output = CharBuffer.allocate(DecoderBufferChars)
        while (true) {
            val result = decoder.decode(input, output, endOfInput)
            output.flip()
            decoded.append(output)
            output.clear()
            if (!result.isOverflow) break
        }

        undecodedBytes = if (!endOfInput && input.hasRemaining()) {
            ByteArray(input.remaining()).also(input::get)
        } else {
            ByteArray(0)
        }

        if (endOfInput) {
            while (true) {
                val result = decoder.flush(output)
                output.flip()
                decoded.append(output)
                output.clear()
                if (!result.isOverflow) break
            }
        }
        return decoded.toString()
    }

    private fun appendDecoded(decoded: String) {
        for (character in decoded) {
            if (pendingCarriageReturn) {
                text.append('\n')
                pendingCarriageReturn = false
                if (character == '\n') continue
            }
            if (character == '\r') {
                pendingCarriageReturn = true
            } else {
                text.append(character)
            }
        }
    }

    private fun flushPendingCarriageReturn() {
        if (!pendingCarriageReturn) return
        text.append('\n')
        pendingCarriageReturn = false
    }

    private fun drainEvents(flushTail: Boolean): List<NetworkEventRecord> {
        if (text.isEmpty()) return emptyList()
        val records = ArrayList<NetworkEventRecord>()
        while (true) {
            val boundary = text.indexOf("\n\n")
            if (boundary < 0) {
                if (flushTail && text.isNotEmpty()) {
                    records += eventRecord(text.toString())
                    text.setLength(0)
                }
                return records
            }
            records += eventRecord(text.substring(0, boundary))
            text.delete(0, boundary + 2)
        }
    }

    private fun eventRecord(raw: String): ResponseStreamEvent {
        val sequence = ++nextSequence
        return ResponseStreamEvent(
            id = requestId,
            tWallMs = wallTimeMillis(),
            tMonoNs = monotonicNanos(),
            sequence = sequence,
            raw = raw,
        )
    }

    private fun emit(record: NetworkEventRecord) {
        try {
            onRecord(record)
        } catch (_: Throwable) {
        }
    }

    private companion object {
        const val DecoderBufferChars: Int = 1024
    }
}

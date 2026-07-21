package com.openai.snapo.network.capture

import android.os.SystemClock
import androidx.annotation.RestrictTo
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
@RestrictTo(RestrictTo.Scope.LIBRARY_GROUP)
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
    private val decoderOutput = CharBuffer.allocate(DecoderBufferChars)
    private val text = StringBuilder()
    private var undecodedBytes = emptyBytes
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
            decodeAndAppend(bytes, offset, length, endOfInput = false)
        }
    }

    fun complete(error: Throwable? = null) {
        synchronized(lock) {
            if (completed) return
            completed = true
            decodeAndAppend(emptyBytes, 0, 0, endOfInput = true)
            flushPendingCarriageReturn()
            if (text.isNotEmpty()) {
                val tail = text.toString()
                text.setLength(0)
                emit(eventRecord(tail))
            }
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

    private fun decodeAndAppend(
        bytes: ByteArray,
        offset: Int,
        length: Int,
        endOfInput: Boolean,
    ) {
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
        while (true) {
            val result = decoder.decode(input, decoderOutput, endOfInput)
            decoderOutput.flip()
            appendDecoded(decoderOutput)
            decoderOutput.clear()
            if (!result.isOverflow) break
        }

        undecodedBytes = if (!endOfInput && input.hasRemaining()) {
            ByteArray(input.remaining()).also(input::get)
        } else {
            emptyBytes
        }

        if (endOfInput) {
            while (true) {
                val result = decoder.flush(decoderOutput)
                decoderOutput.flip()
                appendDecoded(decoderOutput)
                decoderOutput.clear()
                if (!result.isOverflow) break
            }
        }
    }

    private fun appendDecoded(decoded: CharSequence) {
        for (character in decoded) {
            if (pendingCarriageReturn) {
                appendNormalized('\n')
                pendingCarriageReturn = false
                if (character == '\n') continue
            }
            if (character == '\r') {
                pendingCarriageReturn = true
            } else {
                appendNormalized(character)
            }
        }
    }

    private fun flushPendingCarriageReturn() {
        if (!pendingCarriageReturn) return
        appendNormalized('\n')
        pendingCarriageReturn = false
    }

    private fun appendNormalized(character: Char) {
        text.append(character)
        if (character != '\n' || text.length < 2 || text[text.length - 2] != '\n') return
        text.setLength(text.length - 2)
        val event = text.toString()
        text.setLength(0)
        emit(eventRecord(event))
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
        val emptyBytes = ByteArray(0)
    }
}

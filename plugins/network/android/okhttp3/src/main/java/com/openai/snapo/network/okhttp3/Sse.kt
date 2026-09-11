package com.openai.snapo.network.okhttp3

import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.capture.SseStreamCapture
import okhttp3.MediaType
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.Source
import okio.buffer
import java.nio.charset.Charset

internal class StreamingResponseRelayBody(
    private val delegate: ResponseBody,
    requestId: String,
    charset: Charset,
    onRecord: ResponseStreamListener,
) : ResponseBody() {

    private val relay = ResponseStreamRelay(onRecord, requestId, charset)

    private val bufferedSource: BufferedSource by lazy {
        relay.wrapSource(delegate.source()).buffer()
    }

    override fun contentType(): MediaType? = delegate.contentType()

    override fun contentLength(): Long = delegate.contentLength()

    override fun source(): BufferedSource = bufferedSource

    override fun close() {
        val result = runCatching { bufferedSource.close() }
        relay.onClosed(result.exceptionOrNull())
        result.getOrThrow()
    }
}

internal fun interface ResponseStreamListener {
    fun onResponseStreamRecord(recordBuilder: () -> NetworkEventRecord)
}

private class ResponseStreamRelay(
    private val listener: ResponseStreamListener,
    requestId: String,
    charset: Charset,
) {
    private val capture = SseStreamCapture(
        requestId = requestId,
        charset = charset,
    ) { record ->
        listener.onResponseStreamRecord { record }
    }

    fun wrapSource(upstream: Source): Source {
        return object : ForwardingSource(upstream) {
            override fun read(sink: Buffer, byteCount: Long): Long {
                return runCatching {
                    val read = super.read(sink, byteCount)
                    if (read > 0) {
                        val copy = Buffer()
                        sink.copyTo(copy, sink.size - read, read)
                        capture.append(copy.readByteArray())
                    } else if (read == -1L) {
                        onClosed(null)
                    }
                    read
                }.onFailure { error ->
                    onClosed(error)
                }.getOrThrow()
            }

            override fun close() {
                val result = runCatching { super.close() }
                onClosed(result.exceptionOrNull())
                result.getOrThrow()
            }
        }
    }

    fun onClosed(error: Throwable?) {
        capture.complete(error)
    }
}

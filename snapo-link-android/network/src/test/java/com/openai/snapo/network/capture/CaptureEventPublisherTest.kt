package com.openai.snapo.network.capture

import com.openai.snapo.network.NetworkEventRecord
import com.openai.snapo.network.RequestFailed
import com.openai.snapo.network.RequestWillBeSent
import com.openai.snapo.network.ResponseFinished
import com.openai.snapo.network.Timings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.IOException

class CaptureEventPublisherTest {

    @Test
    fun `predecessor gates request publication and lazy body update`() {
        val sink = RecordingSink()
        val predecessor = Job()
        var builderCalls = 0
        var bodyCalls = 0

        publisher(sink).use { publisher ->
            val publication = publisher.publish(after = predecessor) {
                builderCalls += 1
                request("request")
            }
            val bodyUpdate = publisher.updateRequestBody(
                requestId = "request",
                bodyValues = {
                    bodyCalls += 1
                    ResolvedRequestBody(body = "request body", encoding = null)
                },
                bodyTruncatedBytes = 2L,
                bodySize = 14L,
                after = publication,
            )

            assertEquals(0, builderCalls)
            assertEquals(0, bodyCalls)
            assertEquals(emptyList<String>(), sink.operations)

            predecessor.complete()
            await(bodyUpdate)

            assertEquals(1, builderCalls)
            assertEquals(1, bodyCalls)
            assertEquals(
                listOf("publish:RequestWillBeSent", "request:request:request body:null:2:14"),
                sink.operations,
            )
        }
    }

    @Test
    fun `successful response updates the body before publishing finished`() {
        val sink = RecordingSink()

        publisher(sink, wallTime = 123L, monotonicTime = 9_000_000L).use { publisher ->
            await(
                publisher.completeResponse(
                    requestId = "request",
                    requestStartMono = 1_000_000L,
                    capture = capture(byteArrayOf(0, 1, 2, 3), totalBytes = 10L),
                    contentType = BodyContentType.parse("application/octet-stream"),
                    declaredBodySize = null,
                    error = null,
                ),
            )
        }

        assertEquals(
            listOf("response:request:AAE=:AAECAw==:base64:6:10", "publish:ResponseFinished"),
            sink.operations,
        )
        assertEquals(
            ResponseFinished(
                id = "request",
                tWallMs = 123L,
                tMonoNs = 9_000_000L,
                bodySize = 10L,
                bodyTruncatedBytes = 6L,
            ),
            sink.records.single(),
        )
    }

    @Test
    fun `partial response failure updates the body before publishing failure and timing`() {
        val sink = RecordingSink()

        publisher(sink, wallTime = 456L, monotonicTime = 15_000_000L).use { publisher ->
            await(
                publisher.completeResponse(
                    requestId = "request",
                    requestStartMono = 3_000_000L,
                    capture = capture("part".encodeToByteArray(), totalBytes = 4L, reachedEof = false),
                    contentType = BodyContentType.parse("text/plain"),
                    declaredBodySize = 10L,
                    error = IOException("read failed"),
                ),
            )
        }

        assertEquals(listOf("response:request:pa:part:null:6:10", "publish:RequestFailed"), sink.operations)
        assertEquals(
            RequestFailed(
                id = "request",
                tWallMs = 456L,
                tMonoNs = 15_000_000L,
                errorKind = "IOException",
                message = "read failed",
                timings = Timings(totalMs = 12L),
            ),
            sink.records.single(),
        )
    }

    @Test
    fun `sink and resolver failures are isolated and later chained publication still runs`() {
        val sink = RecordingSink(failResponseUpdate = true)

        publisher(sink).use { publisher ->
            val failedRequestUpdate = publisher.updateRequestBody(
                requestId = "request",
                bodyValues = { error("request resolver failed") },
                bodyTruncatedBytes = null,
                bodySize = 4L,
            )
            val responseCompletion = publisher.completeResponse(
                requestId = "request",
                requestStartMono = 0L,
                capture = capture("body".encodeToByteArray(), totalBytes = 4L),
                contentType = BodyContentType.parse("text/plain"),
                declaredBodySize = null,
                error = null,
                after = failedRequestUpdate,
            )
            await(publisher.publish(after = responseCompletion) { request("later") })
        }

        assertEquals(listOf("publish:ResponseFinished", "publish:RequestWillBeSent"), sink.operations)
    }

    @Test
    fun `unavailable sink does not evaluate lazy builders`() {
        var builderCalls = 0
        var bodyCalls = 0

        publisher(sinkProvider = { null }).use { publisher ->
            assertNull(
                publisher.publish {
                    builderCalls += 1
                    request("request")
                },
            )
            assertNull(
                publisher.updateRequestBody(
                    requestId = "request",
                    bodyValues = {
                        bodyCalls += 1
                        ResolvedRequestBody(body = "body", encoding = null)
                    },
                    bodyTruncatedBytes = null,
                    bodySize = 4L,
                ),
            )
        }

        assertEquals(0, builderCalls)
        assertEquals(0, bodyCalls)
    }

    @Test
    fun `sink lookup retries null and caches the first available sink`() {
        val sink = RecordingSink()
        var lookups = 0

        publisher(
            sinkProvider = {
                lookups += 1
                sink.value.takeIf { lookups > 1 }
            },
        ).use { publisher ->
            assertNull(publisher.publish { request("unavailable") })
            await(publisher.publish { request("first") })
            await(publisher.publish { request("second") })
        }

        assertEquals(2, lookups)
        assertEquals(listOf("first", "second"), sink.records.map { (it as RequestWillBeSent).id })
    }

    private fun publisher(
        sink: RecordingSink? = null,
        wallTime: Long = 100L,
        monotonicTime: Long = 1_000_000L,
        sinkProvider: () -> CaptureEventSink? = { checkNotNull(sink).value },
    ): CaptureEventPublisher = CaptureEventPublisher(
        responseBodyPreviewBytes = 2,
        textBodyMaxBytes = 4,
        binaryBodyMaxBytes = 4,
        dispatcher = Dispatchers.Unconfined,
        sinkProvider = sinkProvider,
        wallTimeMillis = { wallTime },
        monotonicNanos = { monotonicTime },
    )

    private fun capture(bytes: ByteArray, totalBytes: Long, reachedEof: Boolean = true): RawResponseBodyCapture =
        RawResponseBodyCapture(bytes = bytes, totalBytes = totalBytes, reachedEof = reachedEof)

    private fun request(id: String): RequestWillBeSent = RequestWillBeSent(
        id = id,
        tWallMs = 1L,
        tMonoNs = 1L,
        method = "GET",
        url = "https://example.com/$id",
        body = null,
        bodyEncoding = null,
        bodyTruncatedBytes = null,
        bodySize = null,
    )

    private fun await(job: Job?) {
        runBlocking { checkNotNull(job).join() }
    }

    private class RecordingSink(failResponseUpdate: Boolean = false) {
        val operations = mutableListOf<String>()
        val records = mutableListOf<NetworkEventRecord>()
        val value = CaptureEventSink(
            publish = {
                records += it
                operations += "publish:${it.javaClass.simpleName}"
            },
            updateRequestBody = { id, body, encoding, truncated, size ->
                operations += "request:$id:$body:$encoding:$truncated:$size"
            },
            updateResponseBody = { id, preview, body, encoding, truncated, size ->
                check(!failResponseUpdate) { "response update failed" }
                operations += "response:$id:$preview:$body:$encoding:$truncated:$size"
            },
        )
    }
}

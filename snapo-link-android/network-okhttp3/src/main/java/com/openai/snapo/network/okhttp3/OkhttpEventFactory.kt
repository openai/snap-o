package com.openai.snapo.network.okhttp3

import com.openai.snapo.network.record.Header
import com.openai.snapo.network.record.RequestWillBeSent
import com.openai.snapo.network.record.ResponseReceived
import com.openai.snapo.network.record.Timings
import okhttp3.Headers
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import java.io.IOException

internal object OkhttpEventFactory {

    fun createRequestWillBeSent(
        context: InterceptContext,
        request: Request,
        body: String?,
        bodyEncoding: String?,
        truncatedBytes: Long?,
    ): RequestWillBeSent =
        RequestWillBeSent(
            id = context.requestId,
            tWallMs = context.startWall,
            tMonoNs = context.startMono,
            method = request.method,
            url = request.url.toString(),
            headers = request.headers.toHeaderList(),
            body = body,
            bodyEncoding = bodyEncoding,
            bodyTruncatedBytes = truncatedBytes,
            bodySize = request.body.safeContentLength(),
        )

    fun createResponseReceived(
        context: InterceptContext,
        response: Response,
        endWall: Long,
        endMono: Long,
        bodyPreview: String?,
        bodyText: String?,
        truncatedBytes: Long?,
        bodySize: Long?,
    ): ResponseReceived =
        ResponseReceived(
            id = context.requestId,
            tWallMs = endWall,
            tMonoNs = endMono,
            code = response.code,
            headers = response.headers.toHeaderList(),
            bodyPreview = bodyPreview,
            body = bodyText,
            bodyTruncatedBytes = truncatedBytes,
            bodySize = bodySize,
            timings = Timings(totalMs = nanosToMillis(endMono - context.startMono)),
        )
}

private fun Headers.toHeaderList(): List<Header> {
    val headerCount = size
    if (headerCount == 0) return emptyList()
    return buildList(headerCount) {
        for (index in 0 until headerCount) {
            add(Header(name(index), value(index)))
        }
    }
}

private fun RequestBody?.safeContentLength(): Long? = this?.let {
    try {
        it.contentLength().takeIf { len -> len >= 0L }
    } catch (_: IOException) {
        null
    }
}

package com.openai.snapo.network.okhttp3

import com.openai.snapo.network.Header
import com.openai.snapo.network.RequestWillBeSent
import com.openai.snapo.network.ResponseReceived
import com.openai.snapo.network.Timings
import okhttp3.Headers
import okhttp3.Request
import okhttp3.Response

internal object OkhttpEventFactory {

    fun createRequestWillBeSent(
        context: InterceptContext,
        request: Request,
        hasBody: Boolean,
        body: String?,
        bodyEncoding: String?,
        truncatedBytes: Long?,
        bodySize: Long?,
    ): RequestWillBeSent =
        RequestWillBeSent(
            id = context.requestId,
            tWallMs = context.startWall,
            tMonoNs = context.startMono,
            method = request.method,
            url = request.url.toString(),
            headers = request.headers.toHeaderList(),
            hasBody = hasBody,
            body = body,
            bodyEncoding = bodyEncoding,
            bodyTruncatedBytes = truncatedBytes,
            bodySize = bodySize,
        )

    fun createResponseReceived(
        context: InterceptContext,
        response: Response,
        endWall: Long,
        endMono: Long,
        bodyPreview: String?,
        bodyText: String?,
        bodyEncoding: String?,
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
            bodyEncoding = bodyEncoding,
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

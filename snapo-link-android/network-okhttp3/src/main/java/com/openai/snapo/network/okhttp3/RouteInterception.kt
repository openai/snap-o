package com.openai.snapo.network.okhttp3

import com.openai.snapo.network.InterceptionDecision
import com.openai.snapo.network.InterceptionHeader
import com.openai.snapo.network.InterceptionRequest
import com.openai.snapo.network.InterceptionResponse
import com.openai.snapo.network.MaxInterceptionBodyBytes
import com.openai.snapo.network.NetworkInterception
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.decodeBase64
import okio.ForwardingSink
import okio.buffer
import java.io.IOException

/** Runs the original call at most once, on its existing OkHttp chain. */
internal fun interceptWithRoutes(
    chain: Interceptor.Chain,
    request: Request,
    interception: NetworkInterception,
): Response {
    if (request.header("Accept")?.contains("text/event-stream", ignoreCase = true) == true) {
        return chain.proceed(request)
    }
    val exchange = interception.open(request.method, request.url.encodedPath) ?: return chain.proceed(request)
    return exchange.use {
        val capturedRequest = request.readRouteBody()
        exchange.request(
            InterceptionRequest(
                method = request.method,
                url = request.url.toString(),
                headerEntries = request.headers.interceptionHeaders(),
                body = capturedRequest.base64(),
            )
        )
        val decision = exchange.awaitDecision { chain.call().isCanceled() }
        if (decision.action != "upstream") {
            return@use decision.toResponse(request)
        }
        // Reuse the bytes already read instead of invoking the app's RequestBody twice.
        val outbound = request.withRouteBody(capturedRequest)
        chain.proceed(outbound).use { upstream ->
            exchange.response(upstream.readRouteResponse())
            exchange.awaitDecision { chain.call().isCanceled() }.toResponse(request, upstream)
        }
    }
}

private fun Request.readRouteBody(): ByteString {
    val requestBody = body ?: return ByteString.EMPTY
    val isUnsupported = requestBody.isDuplex() || requestBody.isOneShot() ||
        requestBody.contentLength() !in 0..MaxInterceptionBodyBytes.toLong()
    if (isUnsupported) throw IOException("Snap-O routes require a repeatable request body of at most 1 MiB")
    val capture = Buffer()
    val sink = object : ForwardingSink(capture) {
        override fun write(source: Buffer, byteCount: Long) {
            if (capture.size + byteCount > MaxInterceptionBodyBytes) {
                throw IOException("Snap-O request body exceeds 1 MiB")
            }
            super.write(source, byteCount)
        }
    }.buffer()
    sink.use { requestBody.writeTo(it) }
    return capture.readByteString()
}

private fun Request.withRouteBody(bytes: ByteString): Request {
    val requestBody = body ?: return this
    return newBuilder().method(method, bytes.toRequestBody(requestBody.contentType())).build()
}

private fun Response.readRouteResponse(): InterceptionResponse {
    if (body.contentType()?.toString()?.startsWith("text/event-stream", ignoreCase = true) == true) {
        throw IOException("Streaming response interception is not supported")
    }
    val source = body.source()
    source.request(MaxInterceptionBodyBytes.toLong() + 1)
    if (source.buffer.size > MaxInterceptionBodyBytes) throw IOException("Snap-O response body exceeds 1 MiB")
    return InterceptionResponse(code, headers.interceptionHeaders(), source.readByteString().base64())
}

private fun InterceptionDecision.toResponse(request: Request, upstream: Response? = null): Response {
    if (action != "fulfill") throw IOException(error ?: "The upstream request has already been sent")
    val replacement = response ?: throw IOException("Missing Snap-O response")
    return replacement.toResponse(request, upstream)
}

private fun InterceptionResponse.toResponse(request: Request, upstream: Response?): Response {
    val bytes = body.decodeBase64() ?: throw IOException("Invalid Snap-O response body")
    if (bytes.size > MaxInterceptionBodyBytes) throw IOException("Snap-O response body exceeds 1 MiB")
    val headers = Headers.Builder().apply {
        headerEntries.forEach { add(it.name, it.value) }
    }.build()
    return (upstream?.newBuilder() ?: Response.Builder().request(request).protocol(Protocol.HTTP_1_1))
        .code(status)
        .message("Snap-O")
        .headers(headers)
        .body(bytes.toResponseBody(headers["Content-Type"]?.toMediaTypeOrNull()))
        .build()
}

private fun Headers.interceptionHeaders(): List<InterceptionHeader> =
    (0 until size).map { InterceptionHeader(name(it), value(it)) }

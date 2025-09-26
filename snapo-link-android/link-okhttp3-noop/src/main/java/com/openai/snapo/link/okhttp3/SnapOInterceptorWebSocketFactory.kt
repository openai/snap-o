@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.link.okhttp3

import java.io.Closeable
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import okhttp3.WebSocket

fun WebSocket.Factory.withSnapOInterceptor(
    textPreviewChars: Int = 0,
    binaryPreviewBytes: Int = 0,
    dispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
): WebSocket.Factory = this

class SnapOInterceptorWebSocketFactory(
    private val delegate: WebSocket.Factory,
    textPreviewChars: Int = 0,
    binaryPreviewBytes: Int = 0,
    dispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
) : WebSocket.Factory by delegate, Closeable {
    override fun close() = Unit
}

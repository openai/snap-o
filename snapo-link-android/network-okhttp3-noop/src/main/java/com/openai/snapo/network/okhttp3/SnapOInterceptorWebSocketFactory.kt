@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.network.okhttp3

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import okhttp3.WebSocket
import java.io.Closeable

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

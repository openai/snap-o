@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.network.httpurlconnection

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import java.io.Closeable
import java.net.HttpURLConnection
import java.net.URL

// No-op implementation for release builds
class SnapOHttpUrlInterceptor(
    private val responseBodyPreviewBytes: Int = 0,
    private val textBodyMaxBytes: Int = 0,
    private val binaryBodyMaxBytes: Int = 0,
    dispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
) : Closeable {

    fun open(url: URL): HttpURLConnection = url.openConnection() as HttpURLConnection

    fun intercept(connection: HttpURLConnection): HttpURLConnection = connection

    override fun close() = Unit
}

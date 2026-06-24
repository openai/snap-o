@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.network.okhttp3

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import okhttp3.Interceptor
import okhttp3.Response
import java.io.Closeable

// No-op implementation for release builds
class SnapOOkHttpInterceptor @JvmOverloads constructor(
    private val responseBodyPreviewBytes: Int = 0,
    private val textBodyMaxBytes: Int = 0,
    private val binaryBodyMaxBytes: Int = 0,
    dispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
) : Interceptor, Closeable {
    override fun intercept(chain: Interceptor.Chain): Response = chain.proceed(chain.request())

    override fun close() = Unit
}

@file:Suppress("UNUSED_PARAMETER")

package com.openai.snapo.link.okhttp3

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import okhttp3.Interceptor
import okhttp3.Response

// No-op implementation for release builds
class SnapOOkHttpInterceptor(
    private val responseBodyPreviewBytes: Long = 0L,
    private val textBodyMaxBytes: Long = 0L,
    dispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response = chain.proceed(chain.request())
}

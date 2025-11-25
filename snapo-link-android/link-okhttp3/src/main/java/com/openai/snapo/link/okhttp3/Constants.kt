package com.openai.snapo.link.okhttp3

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

@Suppress("InjectDispatcher")
internal val DefaultDispatcher: CoroutineDispatcher = Dispatchers.Default
internal const val DefaultBodyPreviewBytes: Int = 4096
internal const val DefaultTextBodyMaxBytes: Int = 5 * 1024 * 1024
internal const val DefaultBinaryBodyMaxBytes: Int = DefaultTextBodyMaxBytes
internal const val DefaultTextPreviewChars: Int = DefaultTextBodyMaxBytes
internal const val DefaultBinaryPreviewBytes: Int = 512

package com.openai.snapo.link.okhttp3

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

internal val DefaultDispatcher: CoroutineDispatcher = Dispatchers.Default
internal const val DefaultBodyPreviewBytes: Int = 4096
internal const val DefaultTextBodyMaxBytes: Int = 1024 * 1024
internal const val DefaultTextPreviewChars: Int = 8 * 1024
internal const val DefaultBinaryPreviewBytes: Int = 64

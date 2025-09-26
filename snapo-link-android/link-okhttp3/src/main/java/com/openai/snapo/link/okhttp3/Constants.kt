package com.openai.snapo.link.okhttp3

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

internal val DefaultDispatcher: CoroutineDispatcher = Dispatchers.Default
internal const val DefaultBodyPreviewBytes: Long = 4096L
internal const val DefaultTextBodyMaxBytes: Long = 256L * 1024L
internal const val DefaultTextPreviewChars: Int = 8 * 1024
internal const val DefaultBinaryPreviewBytes: Int = 64

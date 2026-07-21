package com.openai.snapo.network.okhttp3

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import com.openai.snapo.network.capture.DefaultBinaryBodyMaxBytes as SharedDefaultBinaryBodyMaxBytes
import com.openai.snapo.network.capture.DefaultBodyPreviewBytes as SharedDefaultBodyPreviewBytes
import com.openai.snapo.network.capture.DefaultTextBodyMaxBytes as SharedDefaultTextBodyMaxBytes

@Suppress("InjectDispatcher")
internal val DefaultDispatcher: CoroutineDispatcher = Dispatchers.Default
internal const val DefaultBodyPreviewBytes: Int = SharedDefaultBodyPreviewBytes
internal const val DefaultTextBodyMaxBytes: Int = SharedDefaultTextBodyMaxBytes
internal const val DefaultBinaryBodyMaxBytes: Int = SharedDefaultBinaryBodyMaxBytes
internal const val DefaultTextPreviewChars: Int = DefaultTextBodyMaxBytes
internal const val DefaultBinaryPreviewBytes: Int = 512

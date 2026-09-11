package com.openai.snapo.plugin

/** SSE framing only. Each plugin chooses its own buffering and replay policy. */
object PluginSse {
    fun event(data: String, event: String? = null, id: String? = null): ByteArray {
        require(event == null || event.none { it == '\r' || it == '\n' }) { "Invalid SSE event name" }
        require(id == null || id.none { it == '\r' || it == '\n' || it == '\u0000' }) { "Invalid SSE id" }
        return buildString {
            event?.let { append("event: $it\n") }
            id?.let { append("id: $it\n") }
            data.lineSequence().forEach { append("data: $it\n") }
            append('\n')
        }.toByteArray(Charsets.UTF_8)
    }

    fun heartbeat(): ByteArray = ": keep-alive\n\n".toByteArray(Charsets.US_ASCII)
}

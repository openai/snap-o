package com.openai.snapo.network

import java.io.Closeable

internal data class NetworkReplaySnapshot(
    val messages: List<CdpMessage>,
    val watermark: Long,
)

internal class NetworkToolTransport(
    snapshotProvider: suspend () -> NetworkReplaySnapshot,
    commandHandler: suspend (CdpMessage) -> CdpMessage?,
    interception: NetworkInterception,
) : Closeable {
    private val http = NetworkToolHttp(snapshotProvider, commandHandler, interception)
    fun start(): Boolean = runCatching { http.server.start() }.isSuccess

    override fun close() = http.close()

    fun broadcast(message: CdpMessage) = http.broadcast(message)
}

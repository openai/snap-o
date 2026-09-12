package com.openai.snapo.network

import android.content.Context
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
    fun start(context: Context, allowRelease: Boolean): Boolean = http.server.startIfAllowed(
        context,
        releaseMetadataKey = "snapo.network.allow_release",
        allowRelease = allowRelease,
    )

    override fun close() = http.close()

    fun broadcast(message: CdpMessage) = http.broadcast(message)
}

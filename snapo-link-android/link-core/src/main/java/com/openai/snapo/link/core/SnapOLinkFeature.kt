package com.openai.snapo.link.core

interface SnapOLinkFeature {
    suspend fun onClientConnected(sink: LinkEventSink)
    fun onClientDisconnected()
}

interface LinkEventSink {
    suspend fun sendHighPriority(record: SnapONetRecord)
    suspend fun sendLowPriority(record: SnapONetRecord)
}

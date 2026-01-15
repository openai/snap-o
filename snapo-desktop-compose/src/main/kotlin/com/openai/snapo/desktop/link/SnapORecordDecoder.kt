package com.openai.snapo.desktop.link

import com.openai.snapo.desktop.protocol.AppIcon
import com.openai.snapo.desktop.protocol.FeatureEvent
import com.openai.snapo.desktop.protocol.Hello
import com.openai.snapo.desktop.protocol.LinkRecord
import com.openai.snapo.desktop.protocol.Ndjson
import com.openai.snapo.desktop.protocol.ReplayComplete
import com.openai.snapo.desktop.protocol.SnapONetRecord
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

object SnapORecordDecoder {
    private const val NetworkFeatureId = "network"

    fun decodeNdjsonLine(line: String): SnapORecord {
        val trimmed = line.trimEnd('\n', '\r')
        if (trimmed.isEmpty()) return SnapORecord.Unknown(type = "<empty>", rawJson = line)

        val element = try {
            Ndjson.parseToJsonElement(trimmed)
        } catch (_: Throwable) {
            return SnapORecord.Unknown(type = "<unparseable>", rawJson = trimmed)
        }

        val obj: JsonObject = (element as? JsonObject)
            ?: return SnapORecord.Unknown(type = "<non-object>", rawJson = trimmed)
        val type = (obj["type"] as? JsonPrimitive)?.content
            ?: return SnapORecord.Unknown(type = "<missing-type>", rawJson = trimmed)

        return when (type) {
            "FeatureEvent" -> decodeFeatureEvent(raw = trimmed)
            "Hello" -> decodeCatching(type, trimmed) {
                SnapORecord.HelloRecord(Ndjson.decodeFromString(Hello.serializer(), trimmed))
            }
            "ReplayComplete" -> decodeCatching(type, trimmed) {
                Ndjson.decodeFromString(ReplayComplete.serializer(), trimmed)
                SnapORecord.ReplayComplete
            }
            "AppIcon" -> decodeCatching(type, trimmed) {
                SnapORecord.AppIconRecord(Ndjson.decodeFromString(AppIcon.serializer(), trimmed))
            }

            // Back-compat: allow legacy unwrapped network records (without FeatureEvent envelope).
            "RequestWillBeSent",
            "ResponseReceived",
            "ResponseStreamEvent",
            "ResponseStreamClosed",
            "RequestFailed",
            "WebSocketWillOpen",
            "WebSocketOpened",
            "WebSocketMessageSent",
            "WebSocketMessageReceived",
            "WebSocketClosing",
            "WebSocketClosed",
            "WebSocketFailed",
            "WebSocketCloseRequested",
            "WebSocketCancelled",
            -> decodeNetworkPayload(rawJson = trimmed)

            else -> SnapORecord.Unknown(type = type, rawJson = trimmed)
        }
    }

    private fun decodeFeatureEvent(raw: String): SnapORecord {
        val event = try {
            Ndjson.decodeFromString(LinkRecord.serializer(), raw) as? FeatureEvent
        } catch (_: Throwable) {
            null
        } ?: return SnapORecord.Unknown(type = "FeatureEvent", rawJson = raw)

        if (event.feature != NetworkFeatureId) {
            return SnapORecord.Unknown(type = "FeatureEvent(${event.feature})", rawJson = raw)
        }

        return try {
            val payload = Ndjson.decodeFromJsonElement(SnapONetRecord.serializer(), event.payload)
            SnapORecord.NetworkEvent(payload)
        } catch (_: Throwable) {
            SnapORecord.Unknown(type = "FeatureEvent(${event.feature})", rawJson = raw)
        }
    }

    private fun decodeNetworkPayload(rawJson: String): SnapORecord =
        decodeCatching(type = "NetworkPayload", raw = rawJson) {
            SnapORecord.NetworkEvent(Ndjson.decodeFromString(SnapONetRecord.serializer(), rawJson))
        }

    private inline fun decodeCatching(type: String, raw: String, block: () -> SnapORecord): SnapORecord =
        try {
            block()
        } catch (_: Throwable) {
            SnapORecord.Unknown(type = type, rawJson = raw)
        }
}

package com.openai.snapo.network

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NetworkProtocolCompatibilityTest {
    @Test
    fun `message without a sequence still decodes`() {
        val message = ProtocolJson.decodeFromString(
            CdpMessage.serializer(),
            """{"method":"Network.loadingFinished"}""",
        )

        assertNull(message.snapoSequence)
    }

    @Test
    fun `network sequence is encoded at the message top level`() {
        val encoded = ProtocolJson.encodeToJsonElement(
            CdpMessage.serializer(),
            CdpMessage(
                method = CdpNetworkMethod.LoadingFinished,
                snapoSequence = 7L,
            ),
        ).jsonObject

        assertEquals(7L, encoded.getValue("snapoSequence").jsonPrimitive.content.toLong())
    }

    @Test
    fun `replay completion params carry the snapshot watermark`() {
        val encoded = ProtocolJson.encodeToJsonElement(
            SnapOReplayCompleteParams.serializer(),
            SnapOReplayCompleteParams(watermark = 17L),
        ).jsonObject

        assertEquals(17L, encoded.getValue("watermark").jsonPrimitive.content.toLong())
    }
}

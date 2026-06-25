package com.openai.snapo.network

import kotlinx.coroutines.channels.Channel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayDeliveryTest {
    @Test
    fun `queued live events covered by the replay watermark are skipped`() {
        assertFalse(shouldDeliverAfterReplay(networkEvent(sequence = 40L), watermark = 41L))
        assertFalse(shouldDeliverAfterReplay(networkEvent(sequence = 41L), watermark = 41L))
        assertTrue(shouldDeliverAfterReplay(networkEvent(sequence = 42L), watermark = 41L))
    }

    @Test
    fun `unsequenced events remain compatible with older producers`() {
        assertTrue(shouldDeliverAfterReplay(networkEvent(sequence = null), watermark = 41L))
    }

    @Test
    fun `full channel is reported as a delivery failure`() {
        val channel = Channel<Int>(capacity = 1)

        assertTrue(channel.trySendSuccessfully(1))
        assertFalse(channel.trySendSuccessfully(2))

        channel.close()
    }

    private fun networkEvent(sequence: Long?): CdpMessage = CdpMessage(
        method = CdpNetworkMethod.RequestWillBeSent,
        snapoSequence = sequence,
    )
}

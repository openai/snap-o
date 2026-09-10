package com.openai.snapo.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReplayDeliveryTest {
    @Test
    fun `SSE subscribers close instead of dropping events when their queue fills`() {
        val stream = NetworkEventStream {}
        repeat(512) { assertTrue(stream.offer(byteArrayOf(1))) }
        assertFalse(stream.offer(byteArrayOf(2)))
        assertTrue(stream.isClosed)
    }

    @Test
    fun `SSE subscribers bound queued bytes as well as event count`() {
        val stream = NetworkEventStream {}
        val event = ByteArray(1024 * 1024)
        repeat(32) { assertTrue(stream.offer(event)) }
        assertFalse(stream.offer(event))
        assertTrue(stream.isClosed)
    }
}

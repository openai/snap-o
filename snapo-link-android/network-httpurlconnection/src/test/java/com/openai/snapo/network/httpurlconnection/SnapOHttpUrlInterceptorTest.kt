package com.openai.snapo.network.httpurlconnection

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

class SnapOHttpUrlInterceptorTest {

    @Test
    fun `small known bodies can expand the configured capture limit`() {
        assertEquals(7_000_000, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 7_000_000L))
        assertEquals(1_024, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 512L))
        assertEquals(12 * 1024 * 1024, resolveEffectiveMaxBytes(12 * 1024 * 1024, contentLength = null))
        assertEquals(1_024, resolveEffectiveMaxBytes(maxBytes = 1_024, contentLength = 9L * 1024L * 1024L))
        assertEquals(0, resolveEffectiveMaxBytes(-1, contentLength = null))
    }

    @Test
    fun `capture defaults preserve full body limits`() {
        val interceptor = SnapOHttpUrlInterceptor()
        try {
            assertEquals(5 * 1024 * 1024, interceptor.textBodyMaxBytes)
            assertEquals(interceptor.textBodyMaxBytes, interceptor.binaryBodyMaxBytes)
        } finally {
            interceptor.close()
        }
    }

    @Test
    fun `inactive interceptor returns the original connection`() {
        val connection = FakeHttpURLConnection()
        val interceptor = SnapOHttpUrlInterceptor()
        try {
            assertSame(connection, interceptor.intercept(connection))
        } finally {
            interceptor.close()
        }
    }

    private class FakeHttpURLConnection : HttpURLConnection(URL("https://example.com")) {
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy(): Boolean = false
    }
}

package com.openai.snapo.tweaks.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.IOException

class TweakHttpServerTest {
    @Test
    fun `HTTP rejects rebinding hosts even when the browser omits Origin`() {
        for (host in listOf("attacker.example:1234", "localhost.attacker.example", "127.0.0.1.attacker.example")) {
            for (origin in listOf(null, "http://$host", "http://localhost")) {
                val headers = mapOf("host" to host) + (origin?.let { mapOf("origin" to it) } ?: emptyMap())
                assertThrows(IOException::class.java) { browserOrigin(headers) }
            }
        }
    }

    @Test
    fun `HTTP accepts native clients and loopback browser origins`() {
        for (host in listOf("localhost", "127.0.0.1:1234", "[::1]:1234")) {
            assertNull(browserOrigin(mapOf("host" to host)))
            for (origin in listOf(
                "http://localhost",
                "http://127.0.0.1:5173",
                "http://[::1]:5173",
                "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef"
            )) {
                assertEquals(origin, browserOrigin(mapOf("host" to host, "origin" to origin)))
            }
        }
    }

    @Test
    fun `HTTP rejects missing or malformed hosts and remote or opaque origins`() {
        assertThrows(IOException::class.java) { browserOrigin(emptyMap()) }
        for (host in listOf("", "user@localhost", "localhost/path", "localhost?query", "localhost#fragment")) {
            assertThrows(IOException::class.java) { browserOrigin(mapOf("host" to host)) }
        }
        for (origin in listOf(
            "null", "https://attacker.example", "http://user@localhost", "http://localhost/path",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef:1234",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef/",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef?q=1",
            "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef#fragment",
            "snapo-inspector://user@01234567-89ab-cdef-0123-456789abcdef",
            "snapo-inspector://attacker.example"
        )) {
            assertThrows(IOException::class.java) { browserOrigin(mapOf("host" to "localhost", "origin" to origin)) }
        }
    }
}

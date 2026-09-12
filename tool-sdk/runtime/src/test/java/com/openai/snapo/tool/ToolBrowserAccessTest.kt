package com.openai.snapo.tool

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class ToolBrowserAccessTest {
    @Test
    fun `HTTP rejects rebinding hosts even when the browser omits Origin`() {
        for (host in listOf("attacker.example:1234", "localhost.attacker.example", "127.0.0.1.attacker.example")) {
            for (origin in listOf(null, "http://$host", "http://localhost")) {
                val headers = mapOf("host" to host) + (origin?.let { mapOf("origin" to it) } ?: emptyMap())
                assertThrows(IllegalArgumentException::class.java) { ToolBrowserAccess.origin(headers) }
            }
        }
    }

    @Test
    fun `HTTP accepts native clients and loopback browser origins`() {
        for (host in listOf("localhost", "127.0.0.1:1234", "[::1]:1234")) {
            assertNull(ToolBrowserAccess.origin(mapOf("host" to host)))
            for (origin in listOf(
                "http://localhost",
                "http://127.0.0.1:5173",
                "http://[::1]:5173",
                "snapo-inspector://01234567-89ab-cdef-0123-456789abcdef"
            )) {
                assertEquals(origin, ToolBrowserAccess.origin(mapOf("host" to host, "origin" to origin)))
            }
        }
    }

    @Test
    fun `HTTP rejects missing or malformed hosts and remote or opaque origins`() {
        assertThrows(IllegalArgumentException::class.java) { ToolBrowserAccess.origin(emptyMap()) }
        for (host in listOf("", "user@localhost", "localhost/path", "localhost?query", "localhost#fragment")) {
            assertThrows(IllegalArgumentException::class.java) { ToolBrowserAccess.origin(mapOf("host" to host)) }
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
            assertThrows(IllegalArgumentException::class.java) {
                ToolBrowserAccess.origin(mapOf("host" to "localhost", "origin" to origin))
            }
        }
    }
}

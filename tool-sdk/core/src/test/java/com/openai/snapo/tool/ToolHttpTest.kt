package com.openai.snapo.tool

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException

class ToolHttpTest {
    @Test
    fun `invalid UTF-8 body is a client error`() {
        val request = ToolHttpRequest("POST", "/", emptyMap(), byteArrayOf(0xc3.toByte()))
        val error = assertThrows(ToolHttpException::class.java) { request.bodyText() }
        assertEquals(400, error.statusCode)
    }

    @Test
    fun `request target preserves encoding while query values are decoded separately`() {
        val target = "/items/a%2Fb+z?name=caf%C3%A9&name=a+b&empty=&flag&equals=a%3Db"
        val request = parse("GET $target HTTP/1.1\r\nHost: localhost\r\n\r\n")
        assertEquals(target, request.requestTarget)
        assertEquals("/items/a%2Fb+z", request.path)
        assertEquals(listOf("café", "a b"), request.queryParameters["name"])
        assertEquals(listOf(""), request.queryParameters["empty"])
        assertEquals(listOf(""), request.queryParameters["flag"])
        assertEquals(listOf("a=b"), request.queryParameters["equals"])
        assertTrue(parse("GET /items? HTTP/1.1\r\nHost: localhost\r\n\r\n").queryParameters.isEmpty())
        assertTrue(parse("GET /items HTTP/1.1\r\nHost: localhost\r\n\r\n").queryParameters.isEmpty())
        assertThrows(IllegalArgumentException::class.java) {
            parse("GET /items/%ZZ HTTP/1.1\r\nHost: localhost\r\n\r\n")
        }
    }

    @Test
    fun `request bodies preserve bytes without imposing a content type`() {
        val body = byteArrayOf(0, 0xc3.toByte(), 0xff.toByte())
        for (contentType in listOf("", "Content-Type: text/plain\r\n", "Content-Type: application/octet-stream\r\n")) {
            val head = "PATCH /example HTTP/1.1\r\nHost: localhost\r\nContent-Length: ${body.size}\r\n$contentType\r\n"
            val request = ToolHttpRequest.read(ByteArrayInputStream(head.toByteArray() + body))
            assertTrue(body.contentEquals(request.body))
        }
    }

    @Test
    fun `only HTTP 1_1 requests are accepted`() {
        for (version in listOf("HTTP/1.0", "HTTP/2.0", "HTTP/9.9")) {
            assertThrows(IllegalArgumentException::class.java) {
                parse("GET /example $version\r\nHost: localhost\r\n\r\n")
            }
        }
    }

    @Test
    fun `oversized bodies and invalid origins are rejected before consuming body bytes`() {
        val policy = ToolHttpRequestPolicy(maxBodyBytes = 3)
        val head = "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n" +
            "Content-Type: application/json\r\n\r\n"
        val input = ByteArrayInputStream((head + "test").toByteArray())
        assertEquals(
            413,
            assertThrows(ToolHttpException::class.java) {
                ToolHttpRequest.read(input, policy)
            }.statusCode
        )
        assertEquals(4, input.available())
        val remote = ByteArrayInputStream((head.replace("localhost", "example.test") + "test").toByteArray())
        assertThrows(IllegalArgumentException::class.java) { ToolHttpRequest.read(remote) }
        assertEquals(4, remote.available())
    }

    @Test
    fun `ambiguous framing and unsupported body methods are rejected`() {
        for (headers in listOf(
            "Content-Length: 1\r\nContent-Length: 1\r\n",
            "Content-Length: -1\r\n",
            "Content-Length: +1\r\n",
            "Content-Length: 2147483648\r\n",
            "Transfer-Encoding: chunked\r\n",
            "Bad Header: x\r\n",
        )) {
            assertThrows(IllegalArgumentException::class.java) {
                parse("POST / HTTP/1.1\r\nHost: localhost\r\n$headers\r\nx")
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            parse("GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\nx")
        }
        assertThrows(EOFException::class.java) {
            parse("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\nx")
        }
    }

    @Test
    fun `headers and request lines have independent bounds`() {
        assertThrows(IllegalArgumentException::class.java) {
            parse("GET /${"a".repeat(4096)} HTTP/1.1\r\nHost: localhost\r\n\r\n")
        }
        assertThrows(ToolHttpException::class.java) {
            parse("GET / HTTP/1.1\r\nHost: localhost\r\nX-Fill: ${"a".repeat(16384)}\r\n\r\n")
        }
    }

    @Test
    fun `responses include byte lengths and inspector specific preflight headers`() {
        val body = "café".toByteArray()
        val output = ByteArrayOutputStream()
        ToolHttpResponse(405, body, headers = mapOf("Allow" to "GET, PATCH")).write(
            output,
            ToolBrowserAccess.responseHeaders("http://localhost:5173", "GET, PATCH"),
        )
        val response = output.toString("UTF-8")
        assertTrue(response.startsWith("HTTP/1.1 405 Method Not Allowed\r\n"))
        assertTrue(response.contains("Content-Length: 5\r\n"))
        assertTrue(response.contains("Allow: GET, PATCH\r\n"))
        assertTrue(response.contains("Access-Control-Allow-Methods: GET, PATCH\r\n"))
        assertEquals("café", response.substringAfter("\r\n\r\n"))
        assertThrows(IllegalArgumentException::class.java) {
            ToolHttpResponse(200, byteArrayOf(), headers = mapOf("Location" to "/\r\nInjected: yes")).write(output)
        }
    }

    @Test
    fun `SSE frames multiline data without allowing field injection`() {
        assertEquals(
            "event: update\nid: 7\ndata: first\ndata: second\n\n",
            ToolSse.event("first\r\nsecond", "update", "7").toString(Charsets.UTF_8),
        )
        assertThrows(IllegalArgumentException::class.java) { ToolSse.event("{}", "update\ndata: injected") }
        assertThrows(IllegalArgumentException::class.java) { ToolSse.event("{}", id = "7\u0000") }
    }

    private fun parse(request: String) = ToolHttpRequest.read(ByteArrayInputStream(request.toByteArray()))
}

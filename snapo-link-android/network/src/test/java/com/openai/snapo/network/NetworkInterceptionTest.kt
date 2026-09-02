package com.openai.snapo.network

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.IOException

class NetworkInterceptionTest {
    private val interception = NetworkInterception()
    private val owner = Any()
    private val events = mutableListOf<CdpMessage>()
    private val request = InterceptionRequest("GET", "https://example.test/api/profile", emptyList(), "")

    @Test
    fun `a matching request can fetch upstream once and receive its edited response`() {
        enable()
        assertNull(interception.open("POST", "/api/profile"))
        assertNull(interception.open("GET", "/other"))
        val exchange = requireNotNull(interception.open("GET", "/api/profile"))
        exchange.use {
            exchange.request(request)
            assertEquals("SnapO.intercept.request", events.last().method)
            resolve(exchange, "upstream")
            assertEquals("upstream", exchange.awaitDecision { false }.action)
            assertNotNull(resolve(exchange, "upstream").error)
            exchange.response(InterceptionResponse(200, emptyList(), "e30="))
            assertEquals("SnapO.intercept.response", events.last().method)
            val reply =
                command(
                    "SnapO.intercept.resolve",
                    """
                        {"exchangeId":"${exchange.id}","action":"fulfill",
                         "response":{"status":201,"headerEntries":[],"body":"eyJuYW1lIjoiQ2FwdGFpbiJ9"}}
                    """.trimIndent()
                )
            assertNull(reply.error)
            assertEquals(201, exchange.awaitDecision { false }.response?.status)
        }
        assertEquals("SnapO.intercept.finished", events.last().method)
        assertNotNull(resolve(exchange, "upstream").error)
    }

    @Test
    fun `only the owning connection can resolve requests and disconnect removes its routes`() {
        enable()
        val exchange = requireNotNull(interception.open("GET", "/api/profile"))
        exchange.use {
            exchange.request(request)
            val other = Any()
            assertNull(command("SnapO.intercept.enable", config(path = "/other"), other).error)
            assertNotNull(
                command(
                    "SnapO.intercept.resolve",
                    """{"exchangeId":"${exchange.id}","action":"upstream"}""",
                    other
                ).error
            )
            interception.disconnect(owner)
            assertEquals("fail", exchange.awaitDecision { false }.action)
            assertNull(interception.open("GET", "/api/profile"))
            requireNotNull(interception.open("GET", "/other")).close()
        }
        assertNull(command("SnapO.intercept.enable", config(), Any()).error)
    }

    @Test
    fun `connections replace and disable only their own routes and pending exchanges`() {
        enable()
        val other = Any()
        assertNull(command("SnapO.intercept.enable", config(path = "/other"), other).error)
        val first = requireNotNull(interception.open("GET", "/api/profile"))
        val second = requireNotNull(interception.open("GET", "/other"))
        first.use {
            second.use {
                first.request(request)
                second.request(request.copy(url = "https://example.test/other"))
                assertNull(command("SnapO.intercept.enable", config(path = "/replacement"), other).error)
                assertNull(interception.open("GET", "/other"))
                requireNotNull(interception.open("GET", "/api/profile")).close()
                assertNull(command("SnapO.intercept.disable", "{}", other).error)
                assertNull(interception.open("GET", "/replacement"))
                assertEquals("fail", second.awaitDecision { false }.action)
                assertNull(resolve(first, "upstream").error)
                assertEquals("upstream", first.awaitDecision { false }.action)
            }
        }
    }

    @Test
    fun `reload keeps pending requests tied to their original route generation`() {
        enable()
        val original = requireNotNull(interception.open("GET", "/api/profile"))
        assertNull(command("SnapO.intercept.enable", config("new")).error)
        original.use {
            original.request(request)
            assertEquals("old", (events.last().params as JsonObject)["routeId"]?.jsonPrimitive?.content)
            resolve(original, "fail")
            assertEquals("fail", original.awaitDecision { false }.action)
        }
        requireNotNull(interception.open("GET", "/api/profile")).use { current ->
            assertEquals("new", current.routeId)
        }
    }

    @Test
    fun `a stalled handler and a canceled HTTP call release the waiting thread`() {
        assertNull(command("SnapO.intercept.enable", config(timeout = 100)).error)
        requireNotNull(interception.open("GET", "/api/profile")).use { exchange ->
            exchange.request(request)
            val timeout = assertThrows(IOException::class.java) { exchange.awaitDecision { false } }
            assertEquals("Snap-O handler timed out", timeout.message)
        }
        requireNotNull(interception.open("GET", "/api/profile")).use { exchange ->
            exchange.request(request)
            val cancellation = assertThrows(IOException::class.java) { exchange.awaitDecision { true } }
            assertEquals("Request canceled", cancellation.message)
        }
    }

    private fun enable() { assertNull(command("SnapO.intercept.enable", config()).error) }

    private fun config(id: String = "old", timeout: Long = 30_000, path: String = "/api/profile") =
        """{"routes":[{"id":"$id","method":"GET","path":"$path"}],"timeoutMs":$timeout}"""

    private fun resolve(exchange: NetworkInterception.Exchange, action: String) =
        command("SnapO.intercept.resolve", """{"exchangeId":"${exchange.id}","action":"$action"}""")

    private fun command(method: String, params: String, connection: Any = owner): CdpMessage =
        requireNotNull(
            interception.command(
                connection,
                {
                    events.add(it)
                    true
                },
                CdpMessage(
                    id = 1,
                    method = method,
                    params = ProtocolJson.parseToJsonElement(params),
                )
            )
        )
}

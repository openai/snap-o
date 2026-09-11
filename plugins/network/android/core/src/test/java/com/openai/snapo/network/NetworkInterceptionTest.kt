package com.openai.snapo.network

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
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
            assertThrows(IllegalArgumentException::class.java) { resolve(exchange, "upstream") }
            exchange.response(InterceptionResponse(200, emptyList(), "e30="))
            assertEquals("SnapO.intercept.response", events.last().method)
            interception.resolve(
                owner,
                ProtocolJson.parseToJsonElement(
                    """{"exchangeId":"${exchange.id}","action":"fulfill","phase":"response",
                        "response":{"status":201,"headerEntries":[],"body":"eyJuYW1lIjoiQ2FwdGFpbiJ9"}}"""
                )
            )
            assertEquals(201, exchange.awaitDecision { false }.response?.status)
        }
        assertEquals("SnapO.intercept.finished", events.last().method)
        assertThrows(IllegalArgumentException::class.java) { resolve(exchange, "upstream") }
    }

    @Test
    fun `only the owning connection can resolve requests and disconnect removes its routes`() {
        enable()
        val exchange = requireNotNull(interception.open("GET", "/api/profile"))
        exchange.use {
            exchange.request(request)
            val other = Any()
            configure(config(path = "/other"), other)
            assertThrows(IllegalArgumentException::class.java) {
                resolve(exchange, "upstream", other)
            }
            interception.disconnect(owner)
            assertEquals("fail", exchange.awaitDecision { false }.action)
            assertNull(interception.open("GET", "/api/profile"))
            requireNotNull(interception.open("GET", "/other")).close()
        }
        configure(config(), Any())
    }

    @Test
    fun `connections replace and disable only their own routes and pending exchanges`() {
        enable()
        val other = Any()
        configure(config(path = "/other"), other)
        val first = requireNotNull(interception.open("GET", "/api/profile"))
        val second = requireNotNull(interception.open("GET", "/other"))
        first.use {
            second.use {
                first.request(request)
                second.request(request.copy(url = "https://example.test/other"))
                configure(config(path = "/replacement"), other)
                assertNull(interception.open("GET", "/other"))
                requireNotNull(interception.open("GET", "/api/profile")).close()
                interception.disconnect(other)
                assertNull(interception.open("GET", "/replacement"))
                assertEquals("fail", second.awaitDecision { false }.action)
                resolve(first, "upstream")
                assertEquals("upstream", first.awaitDecision { false }.action)
            }
        }
    }

    @Test
    fun `reload keeps pending requests tied to their original route generation`() {
        enable()
        val original = requireNotNull(interception.open("GET", "/api/profile"))
        configure(config("new"))
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
        configure(config(timeout = 100))
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

    private fun enable() { configure(config()) }

    private fun config(id: String = "old", timeout: Long = 30_000, path: String = "/api/profile") =
        """{"routes":[{"id":"$id","method":"GET","path":"$path"}],"timeoutMs":$timeout}"""

    private fun resolve(exchange: NetworkInterception.Exchange, action: String, runner: Any = owner) =
        interception.resolve(
            runner,
            ProtocolJson.parseToJsonElement(
                """{"exchangeId":"${exchange.id}","action":"$action","phase":"request"}"""
            )
        )

    private fun configure(params: String, runner: Any = owner) {
        interception.configure(runner, {
            events.add(it)
            true
        }, ProtocolJson.parseToJsonElement(params))
    }
}

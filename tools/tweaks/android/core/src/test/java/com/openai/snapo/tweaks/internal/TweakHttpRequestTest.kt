package com.openai.snapo.tweaks.internal

import com.openai.snapo.tool.ToolHttpException
import kotlinx.coroutines.CancellationException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.IOException

class TweakHttpRequestTest {
    @After
    fun clearRegistry() { TweakRegistry.clear() }

    @Test
    fun `JSON failures become client errors without exposing parser messages`() {
        for (failure in listOf(
            IOException("private input"),
            IllegalArgumentException("private input"),
            IllegalStateException("private input"),
        )) {
            val response = assertThrows(ToolHttpException::class.java) { parseTweakRequest { throw failure } }
            assertEquals(400, response.statusCode)
            assertEquals("Malformed JSON request.", response.message)
            assertSame(failure, response.cause)
        }
    }

    @Test
    fun `request parsing preserves successful values and intentional HTTP errors`() {
        assertEquals("example", parseTweakRequest { "example" })
        val failure = ToolHttpException(422, "Invalid value", headers = mapOf("X-Example" to "value"))
        assertSame(failure, assertThrows(ToolHttpException::class.java) { parseTweakRequest { throw failure } })
    }

    @Test
    fun `unexpected failures and cancellation are not translated`() {
        for (failure in listOf(RuntimeException("unexpected"), CancellationException("cancelled"))) {
            assertSame(failure, assertThrows(failure.javaClass) { parseTweakRequest { throw failure } })
        }
    }

    @Test
    fun `numeric limits remain validation errors`() {
        val failure = assertThrows(ToolHttpException::class.java) {
            parseTweakRequest { TweakNumbers.parse("1e100") }
        }
        assertEquals(422, failure.statusCode)
        assertEquals("Numeric tweak value exceeds the supported precision or scale.", failure.message)
    }

    @Test
    fun `missing and conflicted actions preserve their HTTP status`() {
        val missing = assertThrows(ToolHttpException::class.java) { invokeTweakAction("Missing") }
        assertEquals(404, missing.statusCode)
        assertEquals("Unknown action: Missing", missing.message)
        TweakRegistry.registerAction("Example") {}
        TweakRegistry.registerAction("Example") {}
        val conflicted = assertThrows(ToolHttpException::class.java) { invokeTweakAction("Example") }
        assertEquals(409, conflicted.statusCode)
    }

    @Test
    fun `action failures are not mislabeled as malformed requests`() {
        val failure = IllegalStateException("unexpected")
        TweakRegistry.registerAction("Example") { throw failure }
        assertSame(failure, assertThrows(IllegalStateException::class.java) { invokeTweakAction("Example") })
    }
}

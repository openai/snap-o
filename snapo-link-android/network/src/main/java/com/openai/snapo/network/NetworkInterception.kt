package com.openai.snapo.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.buildJsonObject
import java.io.Closeable
import java.io.IOException
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** Connection-owned routes. Inspection clients never receive or control paused requests. */
class NetworkInterception {
    private val lock = Any()
    private var lease: Lease? = null
    private val pending = mutableMapOf<String, Exchange>()

    internal fun command(
        owner: Any,
        send: (CdpMessage) -> Boolean,
        message: CdpMessage,
    ): CdpMessage? {
        if (message.method?.startsWith("SnapO.intercept.") != true) return null
        val id = message.id ?: return null
        return try {
            synchronized(lock) {
                when (message.method) {
                    "SnapO.intercept.enable" -> enable(owner, send, message.params)
                    "SnapO.intercept.disable" -> disconnect(owner)
                    "SnapO.intercept.resolve" -> resolve(owner, message.params)
                    else -> error("Unsupported interception command")
                }
            }
            CdpMessage(id = id, result = buildJsonObject {})
        } catch (error: IllegalArgumentException) {
            CdpMessage(
                id = id,
                error = CdpError(code = -32602, message = error.message ?: "Invalid interception command")
            )
        } catch (error: IllegalStateException) {
            CdpMessage(
                id = id,
                error = CdpError(code = -32602, message = error.message ?: "Invalid interception command")
            )
        }
    }

    private fun enable(owner: Any, send: (CdpMessage) -> Boolean, params: JsonElement?) {
        require(lease == null || lease?.owner === owner) { "Another interception runner is connected" }
        val config = ProtocolJson.decodeFromJsonElement(InterceptionConfig.serializer(), requireNotNull(params))
        require(config.routes.size in 1..128) { "Register between 1 and 128 routes" }
        require(config.timeoutMs in 100..120_000) { "timeoutMs must be between 100 and 120000" }
        require(config.routes.map { it.method to it.path }.distinct().size == config.routes.size) { "Duplicate routes" }
        require(config.routes.map { it.id }.distinct().size == config.routes.size) { "Duplicate route ids" }
        config.routes.forEach {
            require(it.method.matches(Regex("[A-Z]+"))) { "Routes require an uppercase HTTP method" }
            require(it.path.startsWith('/') && '?' !in it.path && '#' !in it.path) {
                "Routes require an absolute path without a query or fragment"
            }
        }
        // In-flight requests keep the handler generation they started with.
        lease = Lease(owner, send, config)
    }

    private fun resolve(owner: Any, params: JsonElement?) {
        require(lease?.owner === owner) { "This connection does not own interception" }
        val decision = ProtocolJson.decodeFromJsonElement(InterceptionDecision.serializer(), requireNotNull(params))
        require(decision.action in setOf("upstream", "fulfill", "fail")) { "Unknown interception action" }
        if (decision.action == "fulfill") {
            val response = requireNotNull(decision.response) { "Missing response" }
            require(response.status in 200..599) { "Response status must be between 200 and 599" }
            require(response.body.length <= MaxInterceptionBodyBytes * 4 / 3 + 4) { "Response body is too large" }
        }
        val exchange = requireNotNull(pending[decision.exchangeId]) { "Request is no longer paused" }
        require(exchange.owner === owner && exchange.offer(decision)) { "Request is not awaiting a decision" }
    }

    internal fun disconnect(owner: Any) = synchronized(lock) {
        if (lease?.owner === owner) lease = null
        pending.values.filter { it.owner === owner }.forEach { it.abort("Interception runner disconnected") }
    }

    /** Returns null without reading the body when no route matches. */
    fun open(method: String, path: String): Exchange? = synchronized(lock) {
        val current = lease ?: return null
        val route = current.config.routes.firstOrNull { it.method == method && it.path == path } ?: return null
        if (pending.size >= 64) throw IOException("Too many paused Snap-O requests")
        val id = UUID.randomUUID().toString()
        Exchange(id, route.id, current.owner, current.send, current.config.timeoutMs).also { pending[id] = it }
    }

    inner class Exchange internal constructor(
        val id: String,
        val routeId: String,
        internal val owner: Any,
        private val send: (CdpMessage) -> Boolean,
        timeoutMs: Long,
    ) : Closeable {
        private val decisions = LinkedBlockingQueue<InterceptionDecision>(1)
        private val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        private var awaiting = false
        private var aborted: String? = null

        fun request(request: InterceptionRequest) = publish(
            "SnapO.intercept.request",
            ProtocolJson.encodeToJsonElement(
                InterceptionRequestEvent.serializer(),
                InterceptionRequestEvent(id, routeId, request),
            )
        )

        fun response(response: InterceptionResponse) = publish(
            "SnapO.intercept.response",
            ProtocolJson.encodeToJsonElement(
                InterceptionResponseEvent.serializer(),
                InterceptionResponseEvent(id, response),
            )
        )

        private fun publish(method: String, params: JsonElement) = synchronized(lock) {
            val failure = aborted ?: if (System.nanoTime() >= deadline) "Snap-O handler timed out" else null
            if (failure != null) throw IOException(failure)
            awaiting = true
            if (!send(CdpMessage(method = method, params = params))) {
                disconnect(owner)
                throw IOException("Interception runner disconnected")
            }
        }

        internal fun offer(decision: InterceptionDecision): Boolean {
            if (!awaiting || aborted != null) return false
            awaiting = false
            return decisions.offer(decision)
        }

        internal fun abort(reason: String) {
            aborted = reason
            decisions.clear()
            decisions.offer(InterceptionDecision(id, "fail", error = reason))
        }

        fun awaitDecision(isCanceled: () -> Boolean): InterceptionDecision {
            while (true) {
                val remaining = deadline - System.nanoTime()
                val failure = when {
                    isCanceled() -> "Request canceled"
                    remaining <= 0 -> "Snap-O handler timed out"
                    else -> null
                }
                if (failure != null) throw IOException(failure)
                val decision = try {
                    decisions.poll(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(100)), TimeUnit.NANOSECONDS)
                } catch (error: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw IOException("Snap-O handler interrupted", error)
                }
                if (decision != null) return decision
            }
        }

        override fun close() = synchronized(lock) {
            pending.remove(id)
            send(
                CdpMessage(
                    method = "SnapO.intercept.finished",
                    params = ProtocolJson.encodeToJsonElement(
                        InterceptionFinishedEvent.serializer(),
                        InterceptionFinishedEvent(id),
                    )
                )
            )
            Unit
        }
    }

    private data class Lease(val owner: Any, val send: (CdpMessage) -> Boolean, val config: InterceptionConfig)
}

const val MaxInterceptionBodyBytes: Int = 1024 * 1024

@Serializable
internal data class InterceptionConfig(val routes: List<InterceptionRoute>, val timeoutMs: Long = 30_000)

@Serializable
internal data class InterceptionRoute(val id: String, val method: String, val path: String)

@Serializable
data class InterceptionHeader(val name: String, val value: String)

@Serializable
data class InterceptionRequest(
    val method: String,
    val url: String,
    val headerEntries: List<InterceptionHeader>,
    val body: String
)

@Serializable
data class InterceptionResponse(val status: Int, val headerEntries: List<InterceptionHeader>, val body: String)

@Serializable
data class InterceptionDecision(
    val exchangeId: String,
    val action: String,
    val response: InterceptionResponse? = null,
    val error: String? = null
)

@Serializable
private data class InterceptionRequestEvent(
    val exchangeId: String,
    val routeId: String,
    val request: InterceptionRequest
)

@Serializable
private data class InterceptionResponseEvent(val exchangeId: String, val response: InterceptionResponse)

@Serializable
private data class InterceptionFinishedEvent(val exchangeId: String)

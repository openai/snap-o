package com.openai.snapo.tool

import java.net.URLDecoder
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Routes are registered once, before the server starts. JSON serialization belongs to the tool plugin. */
class ToolRoutes internal constructor() {
    var requestPolicy = ToolHttpRequestPolicy()
    var exposedHeaders: String? = null
    var vary = "Origin"
    internal val entries = mutableListOf<ToolRoute>()

    fun get(path: String, handler: suspend ToolCall.() -> Unit) = route("GET", path, handler)
    fun post(path: String, handler: suspend ToolCall.() -> Unit) = route("POST", path, handler)
    fun put(path: String, handler: suspend ToolCall.() -> Unit) = route("PUT", path, handler)
    fun patch(path: String, handler: suspend ToolCall.() -> Unit) = route("PATCH", path, handler)
    fun delete(path: String, handler: suspend ToolCall.() -> Unit) = route("DELETE", path, handler)

    /** Sends a heartbeat comment every 30 seconds by default. Null disables automatic heartbeats. */
    fun sse(path: String, heartbeatInterval: Duration? = 30.seconds, handler: suspend ToolSseSession.() -> Unit) {
        require(heartbeatInterval == null || heartbeatInterval.isPositive() && heartbeatInterval.isFinite()) {
            "Heartbeat interval must be positive and finite, or null"
        }
        get(path) { respondSse(heartbeatInterval = heartbeatInterval, block = handler) }
    }

    /** A whole path segment can be a parameter, such as /requests/{id}. */
    fun route(method: String, path: String, handler: suspend ToolCall.() -> Unit) {
        require(method.matches(Regex("[A-Z]+")) && method != "OPTIONS") { "Invalid route method" }
        require(path.startsWith('/') && '?' !in path && '#' !in path) { "Expected a route path" }
        val segments = path.split('/')
        val names = segments.filter { it.startsWith('{') && it.endsWith('}') }.map { it.drop(1).dropLast(1) }
        require(names.all { it.matches(Regex("[a-zA-Z][a-zA-Z0-9]*")) } && names.distinct().size == names.size)
        require(segments.all { ('{' !in it && '}' !in it) || it in names.map { name -> "{$name}" } })
        require(entries.none { it.method == method && it.path == path }) { "Duplicate route: $method $path" }
        entries.add(ToolRoute(method, path, handler))
    }
}

internal class ToolRoute(
    val method: String,
    val path: String,
    val handler: suspend ToolCall.() -> Unit,
) {
    fun match(rawPath: String): Map<String, String>? {
        val expected = path.split('/')
        val actual = rawPath.split('/')
        if (expected.size != actual.size) return null
        val parameters = mutableMapOf<String, String>()
        for ((pattern, value) in expected.zip(actual)) {
            if (pattern.startsWith('{')) {
                if (value.isEmpty()) return null
                parameters[pattern.drop(1).dropLast(1)] = decodePathSegment(value)
            } else if (pattern != value) return null
        }
        return parameters
    }
}

internal fun decodePathSegment(value: String): String = URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")

internal fun defaultErrorResponse(error: Exception): ToolHttpResponse {
    val status = when (error) {
        is ToolHttpException -> error.statusCode
        else -> 500
    }
    val message = if (status == 500) "Internal server error" else error.message ?: "Invalid request"
    return ToolHttpResponse.error(status, message, (error as? ToolHttpException)?.headers.orEmpty())
}

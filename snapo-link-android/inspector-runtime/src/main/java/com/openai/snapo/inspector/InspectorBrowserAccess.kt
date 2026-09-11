package com.openai.snapo.inspector

import java.net.URI

/** Browser access policy for inspector sockets forwarded to loopback. */
object InspectorBrowserAccess {
    fun origin(headers: Map<String, String>): String? {
        val host = headers["host"].orEmpty()
        val authority = runCatching { URI("http://$host") }.getOrNull()
        // Same-origin GETs can omit Origin, so Host must also be checked.
        require(
            authority?.host?.lowercase() in BrowserHosts && authority?.rawAuthority == host &&
                authority.rawUserInfo == null
        ) { "Invalid Host header" }
        val value = headers["origin"] ?: return null
        val origin = runCatching { URI(value) }.getOrNull()
        val allowedAuthority = InspectorOrigin.matches(value) ||
            (origin?.scheme in listOf("http", "https") && origin?.host?.lowercase() in BrowserHosts)
        require(
            allowedAuthority && origin?.rawUserInfo == null && origin?.rawQuery == null &&
                origin?.rawFragment == null && origin?.rawPath.isNullOrEmpty()
        ) { "Cross-origin requests are not allowed" }
        return value
    }

    /** Pass only an origin returned by [origin]. Methods and exposed headers belong to the inspector. */
    fun responseHeaders(
        origin: String?,
        allowedMethods: String,
        exposedHeaders: String? = null,
        vary: String = "Origin",
    ): Map<String, String> = buildMap {
        put("Vary", vary)
        if (origin != null) {
            put("Access-Control-Allow-Origin", origin)
            put("Access-Control-Allow-Methods", allowedMethods)
            put("Access-Control-Allow-Headers", "Content-Type")
            exposedHeaders?.let { put("Access-Control-Expose-Headers", it) }
        }
    }
}

private val BrowserHosts = setOf("localhost", "127.0.0.1", "[::1]")
private val InspectorOrigin = Regex("snapo-inspector://[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

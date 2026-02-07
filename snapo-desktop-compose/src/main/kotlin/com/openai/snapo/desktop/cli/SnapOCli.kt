package com.openai.snapo.desktop.cli

import com.github.ajalt.clikt.core.CliktCommand
import com.github.ajalt.clikt.core.Context
import com.github.ajalt.clikt.core.ProgramResult
import com.github.ajalt.clikt.core.main
import com.github.ajalt.clikt.core.subcommands
import com.github.ajalt.clikt.parameters.arguments.argument
import com.github.ajalt.clikt.parameters.options.flag
import com.github.ajalt.clikt.parameters.options.option
import com.openai.snapo.desktop.adb.AdbExec
import com.openai.snapo.desktop.adb.AdbForwardHandle
import com.openai.snapo.desktop.link.SnapOLinkServerConnection
import com.openai.snapo.desktop.link.SnapORecord
import com.openai.snapo.desktop.protocol.CdpGetResponseBodyParams
import com.openai.snapo.desktop.protocol.CdpGetResponseBodyResult
import com.openai.snapo.desktop.protocol.CdpMessage
import com.openai.snapo.desktop.protocol.CdpNetworkMethod
import com.openai.snapo.desktop.protocol.Ndjson
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.max

object SnapOCli {
    private const val NetworkFeatureId: String = "network"
    private const val SnapshotQuietPeriodMs: Long = 300L
    private const val SnapshotMaxWaitMs: Long = 5_000L
    private const val CommandResponseTimeoutMs: Long = 500L
    private const val CommandAttemptLimit: Int = 3
    private const val RedactedValue: String = "[REDACTED]"

    private val requestHeaderNames = setOf("authorization", "cookie")
    private val responseHeaderNames = setOf("set-cookie")

    fun run(args: Array<String>) {
        RootCommand(this).main(args)
    }

    private suspend fun runNetworkList(): Int {
        val adb = AdbExec()
        val servers = discoverServers(adb)
        servers.forEach { server ->
            printJson(
                CliServerLine(
                    server = server.identifier,
                    deviceId = server.deviceId,
                    socketName = server.socketName,
                )
            )
        }
        return 0
    }

    private suspend fun runNetworkRequests(serverArgument: String, noStream: Boolean): Int {
        val server = parseServerRef(serverArgument) ?: run {
            printError("Invalid server. Expected <deviceId/socketName>, got: $serverArgument")
            return 1
        }

        val adb = AdbExec()
        val session = ServerSession(adb, server)
        val started = session.start()
        if (!started) {
            printError("Failed to connect to ${server.identifier}")
            return 1
        }

        return try {
            if (noStream) {
                if (!runSnapshotRequests(session)) {
                    printError("Timed out waiting for handshake from ${server.identifier}")
                    return 1
                }
            } else {
                runStreamingRequests(session)
            }
            0
        } finally {
            session.close()
        }
    }

    @Suppress("CyclomaticComplexMethod", "LoopWithTooManyJumpStatements")
    private suspend fun runSnapshotRequests(session: ServerSession): Boolean {
        var featureOpenedAtMs: Long? = null
        var lastNetworkEventMs: Long? = null
        val startedAtMs = System.currentTimeMillis()

        while (true) {
            val now = System.currentTimeMillis()
            if (featureOpenedAtMs == null && now - startedAtMs >= SnapshotMaxWaitMs) {
                return false
            }
            val waitMs = snapshotWaitMs(
                nowMs = now,
                openedAtMs = featureOpenedAtMs,
                lastNetworkAtMs = lastNetworkEventMs,
            )

            val record = withTimeoutOrNull(waitMs) {
                session.events.receiveCatching().getOrNull()
            }
            if (record == null) {
                val resolvedOpenedAt = featureOpenedAtMs ?: continue
                val resolvedLastNetworkAt = lastNetworkEventMs ?: resolvedOpenedAt
                val quietForMs = now - resolvedLastNetworkAt
                val elapsedMs = now - resolvedOpenedAt
                if (quietForMs >= SnapshotQuietPeriodMs || elapsedMs >= SnapshotMaxWaitMs) {
                    return true
                }
                continue
            }

            when (record) {
                is SnapORecord.HelloRecord -> {
                    if (featureOpenedAtMs == null) {
                        session.sendFeatureOpened(NetworkFeatureId)
                        featureOpenedAtMs = System.currentTimeMillis()
                    }
                }

                is SnapORecord.NetworkEvent -> {
                    printJson(sanitizeMessage(record.value))
                    lastNetworkEventMs = System.currentTimeMillis()
                }

                else -> Unit
            }
        }
    }

    private suspend fun runStreamingRequests(session: ServerSession) {
        var featureOpened = false
        while (true) {
            val record = session.events.receiveCatching().getOrNull() ?: return
            when (record) {
                is SnapORecord.HelloRecord -> {
                    if (!featureOpened) {
                        session.sendFeatureOpened(NetworkFeatureId)
                        featureOpened = true
                    }
                }

                is SnapORecord.NetworkEvent -> printJson(sanitizeMessage(record.value))
                else -> Unit
            }
        }
    }

    private suspend fun runNetworkResponseBody(requestId: String): Int {
        if (requestId.isBlank()) {
            printError("Request ID cannot be empty")
            return 1
        }

        val adb = AdbExec()
        val servers = discoverServers(adb)
        if (servers.isEmpty()) {
            printError("No Snap-O link servers found")
            return 1
        }

        var lastError: String? = null
        for (server in servers) {
            when (val result = fetchResponseBody(adb, server, requestId)) {
                is FetchResponseBodyResult.Success -> {
                    printJson(
                        CliResponseBodyLine(
                            server = server.identifier,
                            requestId = requestId,
                            body = result.body,
                            base64Encoded = result.base64Encoded,
                        )
                    )
                    return 0
                }

                is FetchResponseBodyResult.MissingBody -> lastError = result.message
                is FetchResponseBodyResult.Failure -> lastError = result.message
            }
        }

        printError(lastError ?: "No response body captured for $requestId")
        return 1
    }

    @Suppress("LongMethod", "CyclomaticComplexMethod", "NestedBlockDepth")
    private suspend fun fetchResponseBody(
        adb: AdbExec,
        server: ServerRef,
        requestId: String,
    ): FetchResponseBodyResult {
        val session = ServerSession(adb, server)
        val started = session.start()
        if (!started) {
            return FetchResponseBodyResult.Failure("Failed to connect to ${server.identifier}")
        }

        return try {
            var featureOpened = false
            var commandId = 1
            var pendingId: Int? = null
            var attempts = 0
            val startedAtMs = System.currentTimeMillis()

            while (attempts < CommandAttemptLimit) {
                val record = withTimeoutOrNull(CommandResponseTimeoutMs) {
                    session.events.receiveCatching().getOrNull()
                }

                when (record) {
                    null -> {
                        if (!featureOpened) {
                            val elapsed = System.currentTimeMillis() - startedAtMs
                            if (elapsed >= SnapshotMaxWaitMs) {
                                return FetchResponseBodyResult.Failure(
                                    "Timed out waiting for handshake from ${server.identifier}"
                                )
                            }
                            continue
                        }
                        if (pendingId != null) {
                            pendingId = null
                        }
                    }

                    is SnapORecord.HelloRecord -> {
                        if (!featureOpened) {
                            session.sendFeatureOpened(NetworkFeatureId)
                            featureOpened = true
                        }
                    }

                    is SnapORecord.NetworkEvent -> {
                        val message = record.value
                        val resolvedPendingId = pendingId
                        if (resolvedPendingId != null && message.id == resolvedPendingId && message.method == null) {
                            val error = message.error
                            if (error != null) {
                                val messageText = error.message
                                return if (messageText.contains("No response body captured", ignoreCase = true)) {
                                    FetchResponseBodyResult.MissingBody(messageText)
                                } else {
                                    FetchResponseBodyResult.Failure(messageText)
                                }
                            }

                            val parsedResult = message.result
                                ?.let { result ->
                                    runCatching {
                                        Ndjson.decodeFromJsonElement(
                                            CdpGetResponseBodyResult.serializer(),
                                            result,
                                        )
                                    }.getOrNull()
                                }
                                ?: return FetchResponseBodyResult.Failure(
                                    "Malformed response for Network.getResponseBody"
                                )

                            return FetchResponseBodyResult.Success(
                                body = parsedResult.body,
                                base64Encoded = parsedResult.base64Encoded,
                            )
                        }
                    }

                    else -> Unit
                }

                if (featureOpened && pendingId == null) {
                    attempts += 1
                    pendingId = commandId
                    val params = Ndjson.encodeToJsonElement(
                        CdpGetResponseBodyParams.serializer(),
                        CdpGetResponseBodyParams(requestId = requestId),
                    )
                    val command = CdpMessage(
                        id = commandId,
                        method = CdpNetworkMethod.GetResponseBody,
                        params = params,
                    )
                    session.sendFeatureCommand(command)
                    commandId += 1
                }
            }

            FetchResponseBodyResult.Failure(
                "Timed out waiting for Network.getResponseBody for $requestId on ${server.identifier}"
            )
        } finally {
            session.close()
        }
    }

    private suspend fun discoverServers(adb: AdbExec): List<ServerRef> {
        val devicesOutput = runCatching { adb.devicesList() }.getOrElse { return emptyList() }
        val deviceIds = parseConnectedDeviceIds(devicesOutput)
        if (deviceIds.isEmpty()) return emptyList()

        val result = ArrayList<ServerRef>()
        for (deviceId in deviceIds) {
            val socketsOutput = runCatching { adb.listUnixSockets(deviceId) }.getOrNull() ?: continue
            val sockets = parseSnapOServerSockets(socketsOutput)
            sockets.forEach { socketName ->
                result.add(
                    ServerRef(
                        deviceId = deviceId,
                        socketName = socketName,
                    )
                )
            }
        }
        return result.sortedWith(compareBy<ServerRef> { it.deviceId }.thenBy { it.socketName })
    }

    private fun parseConnectedDeviceIds(output: String): List<String> {
        val invalidStates = listOf("offline", "unauthorized", "recovery", "authorizing")
        val result = LinkedHashSet<String>()
        output.lineSequence().forEach { line ->
            val trimmed = line.trim()
            if (trimmed.isEmpty()) return@forEach
            val parts = trimmed.split(Regex("\\s+"))
            val id = parts.firstOrNull().orEmpty()
            if (id.isBlank()) return@forEach
            val state = parts.getOrNull(1)?.lowercase().orEmpty()
            if (invalidStates.any(state::contains)) return@forEach
            result.add(id)
        }
        return result.toList()
    }

    private fun parseSnapOServerSockets(output: String): List<String> {
        val result = LinkedHashSet<String>()
        output.lineSequence().forEach { rawLine ->
            val token = rawLine.trim()
                .takeIf { it.isNotEmpty() }
                ?.split(Regex("\\s+"))
                ?.lastOrNull()
            if (token != null && token.startsWith("@snapo_server_")) {
                result.add(token.removePrefix("@"))
            }
        }
        return result.toList()
    }

    private fun parseServerRef(value: String): ServerRef? {
        val separator = value.indexOf('/')
        if (separator <= 0 || separator >= value.lastIndex) return null
        val deviceId = value.substring(0, separator).trim()
        val socketName = value.substring(separator + 1).trim()
        if (deviceId.isEmpty() || socketName.isEmpty()) return null
        return ServerRef(deviceId = deviceId, socketName = socketName)
    }

    private fun snapshotWaitMs(
        nowMs: Long,
        openedAtMs: Long?,
        lastNetworkAtMs: Long?,
    ): Long {
        if (openedAtMs == null) return 250L

        val elapsedSinceOpen = nowMs - openedAtMs
        if (elapsedSinceOpen >= SnapshotMaxWaitMs) return 1L

        val quietRemaining = if (lastNetworkAtMs == null) {
            SnapshotQuietPeriodMs
        } else {
            max(1L, SnapshotQuietPeriodMs - (nowMs - lastNetworkAtMs))
        }
        val maxRemaining = max(1L, SnapshotMaxWaitMs - elapsedSinceOpen)
        return minOf(quietRemaining, maxRemaining)
    }

    private fun sanitizeMessage(message: CdpMessage): CdpMessage {
        val method = message.method ?: return message
        val params = message.params ?: return message
        val sanitizedParams = when (method) {
            CdpNetworkMethod.RequestWillBeSent -> redactHeadersAtPath(
                params,
                listOf("request", "headers"),
                requestHeaderNames,
            )

            CdpNetworkMethod.ResponseReceived -> redactHeadersAtPath(
                params,
                listOf("response", "headers"),
                responseHeaderNames,
            )

            CdpNetworkMethod.WebSocketCreated -> redactHeadersAtPath(
                params,
                listOf("headers"),
                requestHeaderNames,
            )

            CdpNetworkMethod.WebSocketHandshakeResponseReceived -> {
                redactHeadersAtPath(
                    params,
                    listOf("response", "headers"),
                    responseHeaderNames,
                )
            }

            else -> params
        }

        return if (sanitizedParams == params) message else message.copy(params = sanitizedParams)
    }

    private fun redactHeadersAtPath(
        root: JsonElement,
        path: List<String>,
        sensitiveHeaderNames: Set<String>,
    ): JsonElement {
        if (path.isEmpty()) {
            val headers = root as? JsonObject ?: return root
            var changed = false
            val updated = LinkedHashMap<String, JsonElement>(headers.size)
            headers.forEach { (name, value) ->
                if (sensitiveHeaderNames.any { sensitive -> sensitive.equals(name, ignoreCase = true) }) {
                    updated[name] = JsonPrimitive(RedactedValue)
                    changed = true
                } else {
                    updated[name] = value
                }
            }
            return if (changed) JsonObject(updated) else root
        }

        val obj = root as? JsonObject ?: return root
        val key = path.first()
        val child = obj[key] ?: return root
        val updatedChild = redactHeadersAtPath(
            root = child,
            path = path.drop(1),
            sensitiveHeaderNames = sensitiveHeaderNames,
        )
        if (updatedChild == child) return root

        val updated = LinkedHashMap<String, JsonElement>(obj.size)
        obj.forEach { (name, value) ->
            updated[name] = if (name == key) updatedChild else value
        }
        return JsonObject(updated)
    }

    private fun printError(message: String) {
        System.err.println("snapo: $message")
    }

    private inline fun <reified T> printJson(payload: T) {
        println(Ndjson.encodeToString(payload))
    }

    @Serializable
    private data class CliServerLine(
        val server: String,
        val deviceId: String,
        val socketName: String,
    )

    @Serializable
    private data class CliResponseBodyLine(
        val server: String,
        val requestId: String,
        val body: String,
        val base64Encoded: Boolean,
    )

    private data class ServerRef(
        val deviceId: String,
        val socketName: String,
    ) {
        val identifier: String
            get() = "$deviceId/$socketName"
    }

    private sealed interface FetchResponseBodyResult {
        data class Success(
            val body: String,
            val base64Encoded: Boolean,
        ) : FetchResponseBodyResult

        data class MissingBody(
            val message: String,
        ) : FetchResponseBodyResult

        data class Failure(
            val message: String,
        ) : FetchResponseBodyResult
    }

    private class ServerSession(
        private val adb: AdbExec,
        private val server: ServerRef,
    ) {
        val events: Channel<SnapORecord> = Channel(Channel.UNLIMITED)

        private var forwardHandle: AdbForwardHandle? = null
        private var connection: SnapOLinkServerConnection? = null

        suspend fun start(): Boolean {
            val handle = runCatching {
                adb.forwardLocalAbstract(server.deviceId, server.socketName)
            }.getOrNull() ?: return false

            val sessionConnection = SnapOLinkServerConnection(
                port = handle.localPort,
                onEvent = { record ->
                    events.trySend(record)
                },
                onClose = { _ ->
                    events.close()
                },
            )
            forwardHandle = handle
            connection = sessionConnection
            sessionConnection.start()
            return true
        }

        fun sendFeatureOpened(feature: String) {
            connection?.sendFeatureOpened(feature)
        }

        fun sendFeatureCommand(command: CdpMessage) {
            val payload = Ndjson.encodeToJsonElement(CdpMessage.serializer(), command)
            connection?.sendFeatureCommand(
                feature = NetworkFeatureId,
                payload = payload,
            )
        }

        suspend fun close() {
            runCatching { connection?.stop() }
            connection = null

            forwardHandle?.let { handle ->
                runCatching { adb.removeForward(handle) }
            }
            forwardHandle = null
            events.close()
        }
    }

    private class RootCommand(
        private val runtime: SnapOCli,
    ) : CliktCommand(name = "snapo") {
        override fun help(context: Context): String = "Snap-O command line tools"
        override val printHelpOnEmptyArgs: Boolean = true

        init {
            subcommands(NetworkCommand(runtime))
        }

        override fun run() = Unit
    }

    private class NetworkCommand(
        private val runtime: SnapOCli,
    ) : CliktCommand(name = "network") {
        override fun help(context: Context): String = "Inspect Snap-O network data"
        override val printHelpOnEmptyArgs: Boolean = true

        init {
            subcommands(
                NetworkListCommand(runtime),
                NetworkRequestsCommand(runtime),
                NetworkResponseBodyCommand(runtime),
            )
        }

        override fun run() = Unit
    }

    private class NetworkListCommand(
        private val runtime: SnapOCli,
    ) : CliktCommand(name = "list") {
        override fun help(context: Context): String = "List available Snap-O link servers"

        override fun run() = runBlocking {
            val exitCode = runtime.runNetworkList()
            if (exitCode != 0) throw ProgramResult(exitCode)
        }
    }

    private class NetworkRequestsCommand(
        private val runtime: SnapOCli,
    ) : CliktCommand(name = "requests") {
        override fun help(context: Context): String = "Emit CDP network events for a server"

        private val server by argument(
            name = "server",
            help = "<deviceId/socketName>",
        )
        private val noStream by option(
            "--no-stream",
            help = "Emit only the buffered snapshot and then exit",
        ).flag(default = false)

        override fun run() = runBlocking {
            val exitCode = runtime.runNetworkRequests(
                serverArgument = server,
                noStream = noStream,
            )
            if (exitCode != 0) throw ProgramResult(exitCode)
        }
    }

    private class NetworkResponseBodyCommand(
        private val runtime: SnapOCli,
    ) : CliktCommand(name = "response-body") {
        override fun help(context: Context): String = "Fetch response body for a request id"

        private val requestId by argument(
            name = "requestId",
            help = "CDP request id",
        )

        override fun run() = runBlocking {
            val exitCode = runtime.runNetworkResponseBody(requestId)
            if (exitCode != 0) throw ProgramResult(exitCode)
        }
    }
}

@file:Suppress("ImportOrdering")

package com.openai.snapo.desktop.cli

import com.github.ajalt.clikt.core.CliktCommand
import com.github.ajalt.clikt.core.Context
import com.github.ajalt.clikt.core.ProgramResult
import com.github.ajalt.clikt.core.main
import com.github.ajalt.clikt.core.subcommands
import com.github.ajalt.clikt.parameters.arguments.argument
import com.github.ajalt.clikt.parameters.options.flag
import com.github.ajalt.clikt.parameters.options.option
import com.github.ajalt.clikt.parameters.options.required
import com.openai.snapo.desktop.adb.AdbExec
import com.openai.snapo.desktop.adb.AdbForwardHandle
import com.openai.snapo.desktop.link.SnapOLinkServerConnection
import com.openai.snapo.desktop.link.SnapORecord
import com.openai.snapo.desktop.protocol.CdpGetResponseBodyParams
import com.openai.snapo.desktop.protocol.CdpGetResponseBodyResult
import com.openai.snapo.desktop.protocol.CdpLoadingFailedParams
import com.openai.snapo.desktop.protocol.CdpLoadingFinishedParams
import com.openai.snapo.desktop.protocol.CdpMessage
import com.openai.snapo.desktop.protocol.CdpNetworkMethod
import com.openai.snapo.desktop.protocol.CdpRequestWillBeSentParams
import com.openai.snapo.desktop.protocol.CdpResponseReceivedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameReceivedParams
import com.openai.snapo.desktop.protocol.CdpWebSocketFrameSentParams
import com.openai.snapo.desktop.protocol.Hello
import com.openai.snapo.desktop.protocol.Ndjson
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.serializer
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
    private const val HelloWaitTimeoutMs: Long = 1_200L
    private const val RedactedValue: String = "[REDACTED]"

    private val requestHeaderNames = setOf("authorization", "cookie")
    private val responseHeaderNames = setOf("set-cookie")

    private enum class OutputMode {
        Human,
        Json,
    }

    fun run(args: Array<String>) {
        RootCommand(this).main(args)
    }

    private suspend fun runNetworkList(
        deviceSelection: DeviceSelectionOptions,
        includeAppInfo: Boolean,
        outputMode: OutputMode,
    ): Int {
        val adb = AdbExec()
        val discovery = discoverServers(adb, deviceSelection)
        val servers = when (discovery) {
            is ServerDiscoveryResult.Success -> discovery.servers
            is ServerDiscoveryResult.Failure -> {
                printError(discovery.message)
                return 1
            }
        }
        if (servers.isEmpty()) {
            printError("No Snap-O link servers found")
            return 1
        }

        val appInfoByServer = if (includeAppInfo) {
            servers.associateWith { resolveServerAppInfo(adb, it) }
        } else {
            emptyMap()
        }

        when (outputMode) {
            OutputMode.Json -> {
                servers.forEach { server ->
                    val appInfo = appInfoByServer[server]
                    emitServerLine(
                        line = CliServerWithAppInfoLine(
                            server = server.identifier,
                            deviceId = server.deviceId,
                            socketName = server.socketName,
                            packageName = appInfo?.packageName,
                            appName = appInfo?.appName,
                        ),
                        outputMode = OutputMode.Json,
                    )
                }
            }

            OutputMode.Human -> emitServerListHuman(
                servers = servers,
                appInfoByServer = appInfoByServer.takeIf { includeAppInfo },
            )
        }

        return 0
    }

    private suspend fun runNetworkRequests(
        deviceSelection: DeviceSelectionOptions,
        socketArgument: String,
        noStream: Boolean,
        outputMode: OutputMode,
    ): Int {
        val adb = AdbExec()
        val resolved = resolveServer(adb = adb, socketArgument = socketArgument, deviceSelection = deviceSelection)
        val server = when (resolved) {
            is ServerResolutionResult.Success -> resolved.server
            is ServerResolutionResult.Failure -> {
                printError(resolved.message)
                return 1
            }
        }

        val session = ServerSession(adb, server)
        val started = session.start()
        if (!started) {
            printError("Failed to connect to ${server.identifier}")
            return 1
        }

        return try {
            if (noStream) {
                if (!runSnapshotRequests(session, outputMode)) {
                    printError("Timed out waiting for handshake from ${server.identifier}")
                    return 1
                }
            } else {
                runStreamingRequests(session, outputMode)
            }
            0
        } finally {
            session.close()
        }
    }

    @Suppress("CyclomaticComplexMethod", "LoopWithTooManyJumpStatements")
    private suspend fun runSnapshotRequests(session: ServerSession, outputMode: OutputMode): Boolean {
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
                    emitNetworkEvent(message = sanitizeMessage(record.value), outputMode = outputMode)
                    lastNetworkEventMs = System.currentTimeMillis()
                }

                else -> Unit
            }
        }
    }

    private suspend fun runStreamingRequests(session: ServerSession, outputMode: OutputMode) {
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

                is SnapORecord.NetworkEvent -> {
                    emitNetworkEvent(message = sanitizeMessage(record.value), outputMode = outputMode)
                }
                else -> Unit
            }
        }
    }

    private suspend fun runNetworkResponseBody(
        deviceSelection: DeviceSelectionOptions,
        socketArgument: String,
        requestId: String,
        outputMode: OutputMode,
    ): Int {
        if (requestId.isBlank()) {
            printError("Request ID cannot be empty")
            return 1
        }

        val adb = AdbExec()
        val resolved = resolveServer(adb = adb, socketArgument = socketArgument, deviceSelection = deviceSelection)
        val server = when (resolved) {
            is ServerResolutionResult.Success -> resolved.server
            is ServerResolutionResult.Failure -> {
                printError(resolved.message)
                return 1
            }
        }

        return when (val result = fetchResponseBody(adb, server, requestId)) {
            is FetchResponseBodyResult.Success -> {
                emitResponseBody(
                    line = CliResponseBodyLine(
                        server = server.identifier,
                        requestId = requestId,
                        body = result.body,
                        base64Encoded = result.base64Encoded,
                    ),
                    outputMode = outputMode,
                )
                0
            }

            is FetchResponseBodyResult.MissingBody -> {
                printError(result.message)
                1
            }

            is FetchResponseBodyResult.Failure -> {
                printError(result.message)
                1
            }
        }
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

    private suspend fun discoverServers(
        adb: AdbExec,
        deviceSelection: DeviceSelectionOptions,
    ): ServerDiscoveryResult {
        val devicesOutput = runCatching { adb.devicesList() }.getOrElse {
            return ServerDiscoveryResult.Failure("Failed to list adb devices")
        }
        val deviceIds = parseConnectedDeviceIds(devicesOutput)
        if (deviceIds.isEmpty()) {
            return ServerDiscoveryResult.Failure("No connected devices found")
        }

        val selectedDeviceIds = when (val selection = resolveTargetDeviceIds(deviceIds, deviceSelection)) {
            is DeviceSelectionResult.Success -> selection.deviceIds
            is DeviceSelectionResult.Failure -> return ServerDiscoveryResult.Failure(selection.message)
        }

        val result = ArrayList<ServerRef>()
        for (deviceId in selectedDeviceIds) {
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
        return ServerDiscoveryResult.Success(
            result.sortedWith(compareBy<ServerRef> { it.deviceId }.thenBy { it.socketName })
        )
    }

    private suspend fun resolveServerAppInfo(adb: AdbExec, server: ServerRef): ServerAppInfo {
        val hint = packageNameHint(adb, server)
        val hello = fetchHello(adb, server)
        val packageName = hello?.packageName ?: hint
        val appName = hello?.processName?.takeIf { it.isNotBlank() }
        return ServerAppInfo(
            packageName = packageName,
            appName = appName,
        )
    }

    private suspend fun fetchHello(adb: AdbExec, server: ServerRef): Hello? {
        val session = ServerSession(adb, server)
        val started = session.start()
        if (!started) return null

        var hello: Hello? = null
        try {
            while (hello == null) {
                val next = withTimeoutOrNull(HelloWaitTimeoutMs) {
                    session.events.receiveCatching().getOrNull()
                } ?: break
                if (next is SnapORecord.HelloRecord) {
                    hello = next.value
                }
            }
        } finally {
            session.close()
        }
        return hello
    }

    private suspend fun packageNameHint(adb: AdbExec, server: ServerRef): String? {
        val pid = pidFromSocketName(server.socketName) ?: return null
        val output = runCatching {
            adb.runShellString(server.deviceId, "cat /proc/$pid/cmdline 2>/dev/null")
        }.getOrNull() ?: return null

        return output
            .split('\u0000')
            .firstOrNull { it.isNotBlank() }
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?: output.lineSequence().firstOrNull()?.trim()?.takeIf { it.isNotBlank() }
    }

    private fun pidFromSocketName(socketName: String): Int? {
        val prefix = "snapo_server_"
        if (!socketName.startsWith(prefix)) return null
        val suffix = socketName.removePrefix(prefix)
        if (suffix.isBlank() || suffix.any { !it.isDigit() }) return null
        return suffix.toIntOrNull()
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

    private fun resolveTargetDeviceIds(
        connectedDeviceIds: List<String>,
        deviceSelection: DeviceSelectionOptions,
    ): DeviceSelectionResult {
        val hasSerial = !deviceSelection.serialId.isNullOrBlank()
        val selectedByCount = listOf(
            hasSerial,
            deviceSelection.useUsbDevice,
            deviceSelection.useEmulator,
        ).count { it }
        if (selectedByCount > 1) {
            return DeviceSelectionResult.Failure("Options -s, -d, and -e are mutually exclusive")
        }

        val serial = deviceSelection.serialId?.trim()?.takeIf { it.isNotEmpty() }
        if (serial != null) {
            return if (connectedDeviceIds.contains(serial)) {
                DeviceSelectionResult.Success(listOf(serial))
            } else {
                DeviceSelectionResult.Failure("Device '$serial' is not connected")
            }
        }

        if (deviceSelection.useEmulator) {
            val emulators = connectedDeviceIds.filter(::isEmulatorDeviceId)
            return when {
                emulators.isEmpty() -> DeviceSelectionResult.Failure("No emulator connected")
                emulators.size > 1 -> {
                    DeviceSelectionResult.Failure("More than one emulator connected; use -s <serial>")
                }

                else -> DeviceSelectionResult.Success(emulators)
            }
        }

        if (deviceSelection.useUsbDevice) {
            val usbDevices = connectedDeviceIds.filterNot(::isEmulatorDeviceId)
            return when {
                usbDevices.isEmpty() -> DeviceSelectionResult.Failure("No USB device connected")
                usbDevices.size > 1 -> {
                    DeviceSelectionResult.Failure("More than one USB device connected; use -s <serial>")
                }

                else -> DeviceSelectionResult.Success(usbDevices)
            }
        }

        return DeviceSelectionResult.Success(connectedDeviceIds)
    }

    private fun isEmulatorDeviceId(deviceId: String): Boolean =
        deviceId.startsWith("emulator-")

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

    private suspend fun resolveServer(
        adb: AdbExec,
        socketArgument: String,
        deviceSelection: DeviceSelectionOptions,
    ): ServerResolutionResult {
        val socketName = socketArgument.trim()
        if (socketName.isEmpty()) {
            return ServerResolutionResult.Failure("Socket name cannot be empty")
        }

        val discovery = discoverServers(adb, deviceSelection)
        val servers = when (discovery) {
            is ServerDiscoveryResult.Success -> discovery.servers
            is ServerDiscoveryResult.Failure -> return ServerResolutionResult.Failure(discovery.message)
        }
        if (servers.isEmpty()) {
            return ServerResolutionResult.Failure("No Snap-O link servers found for selected device(s)")
        }

        val qualified = parseServerRef(socketName)
        if (qualified != null) {
            val exactMatch = servers.firstOrNull { it == qualified }
            return if (exactMatch != null) {
                ServerResolutionResult.Success(exactMatch)
            } else {
                ServerResolutionResult.Failure(
                    "Server '${qualified.identifier}' was not found for selected device(s)"
                )
            }
        }

        val matches = servers.filter { it.socketName == socketName }
        return when {
            matches.isEmpty() -> {
                ServerResolutionResult.Failure("No Snap-O link server named '$socketName' found")
            }

            matches.size > 1 -> {
                ServerResolutionResult.Failure(
                    "Socket '$socketName' exists on multiple devices; use -s <serial>, -d, or -e"
                )
            }

            else -> ServerResolutionResult.Success(matches.first())
        }
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

    private fun emitServerListHuman(
        servers: List<ServerRef>,
        appInfoByServer: Map<ServerRef, ServerAppInfo>?,
    ) {
        val byDevice = servers.groupBy { it.deviceId }.toSortedMap()
        byDevice.forEach { (deviceId, deviceServers) ->
            println("$deviceId:")
            deviceServers
                .sortedBy { it.socketName }
                .forEach { server ->
                    if (appInfoByServer == null) {
                        println("    ${server.socketName}")
                        return@forEach
                    }
                    val packageName = appInfoByServer[server]?.packageName ?: "unknown"
                    println("    ${server.socketName}  pkg:$packageName")
                }
        }
    }

    private fun emitServerLine(line: CliServerLine, outputMode: OutputMode) {
        when (outputMode) {
            OutputMode.Json -> printJson(line)
            OutputMode.Human -> {
                println("${line.server} (device=${line.deviceId}, socket=${line.socketName})")
            }
        }
    }

    private fun emitServerLine(line: CliServerWithAppInfoLine, outputMode: OutputMode) {
        when (outputMode) {
            OutputMode.Json -> printJson(line)
            OutputMode.Human -> {
                val packagePart = line.packageName ?: "unknown"
                val appPart = line.appName ?: "unknown"
                println(
                    "${line.server} (device=${line.deviceId}, socket=${line.socketName}, " +
                        "package=$packagePart, app=$appPart)"
                )
            }
        }
    }

    private fun emitNetworkEvent(message: CdpMessage, outputMode: OutputMode) {
        when (outputMode) {
            OutputMode.Json -> printJson(message)
            OutputMode.Human -> println(formatNetworkEventLine(message))
        }
    }

    private fun emitResponseBody(line: CliResponseBodyLine, outputMode: OutputMode) {
        when (outputMode) {
            OutputMode.Json -> printJson(line)
            OutputMode.Human -> {
                println("Server: ${line.server}")
                println("Request ID: ${line.requestId}")
                println("Base64 Encoded: ${line.base64Encoded}")
                println("Body:")
                println(line.body)
            }
        }
    }

    @Suppress("CyclomaticComplexMethod")
    private fun formatNetworkEventLine(message: CdpMessage): String {
        val method = message.method
        if (method == null) {
            return "EVENT ${Ndjson.encodeToString(CdpMessage.serializer(), message)}"
        }

        return when (method) {
            CdpNetworkMethod.RequestWillBeSent -> {
                val params = decodeParams<CdpRequestWillBeSentParams>(message) ?: return "REQUEST ?"
                "REQUEST ${params.requestId} ${params.request.method} ${params.request.url}"
            }

            CdpNetworkMethod.ResponseReceived -> {
                val params = decodeParams<CdpResponseReceivedParams>(message) ?: return "RESPONSE ?"
                val url = params.response.url ?: "unknown-url"
                "RESPONSE ${params.requestId} ${params.response.status} $url"
            }

            CdpNetworkMethod.LoadingFinished -> {
                val params = decodeParams<CdpLoadingFinishedParams>(message) ?: return "FINISH ?"
                val bytes = params.encodedDataLength?.toLong() ?: 0L
                "FINISH ${params.requestId} bytes=$bytes"
            }

            CdpNetworkMethod.LoadingFailed -> {
                val params = decodeParams<CdpLoadingFailedParams>(message) ?: return "FAIL ?"
                val error = params.errorText ?: params.type ?: "unknown-error"
                "FAIL ${params.requestId} $error"
            }

            CdpNetworkMethod.WebSocketFrameSent -> {
                val params = decodeParams<CdpWebSocketFrameSentParams>(message) ?: return "WS-SENT ?"
                "WS-SENT ${params.requestId} opcode=${params.response.opcode} size=${params.response.payloadSize ?: 0L}"
            }

            CdpNetworkMethod.WebSocketFrameReceived -> {
                val params = decodeParams<CdpWebSocketFrameReceivedParams>(message) ?: return "WS-RECV ?"
                "WS-RECV ${params.requestId} opcode=${params.response.opcode} size=${params.response.payloadSize ?: 0L}"
            }

            else -> "EVENT $method"
        }
    }

    private inline fun <reified T> decodeParams(message: CdpMessage): T? {
        val params = message.params ?: return null
        return runCatching {
            Ndjson.decodeFromJsonElement(serializer<T>(), params)
        }.getOrNull()
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
    private data class CliServerWithAppInfoLine(
        val server: String,
        val deviceId: String,
        val socketName: String,
        val packageName: String? = null,
        val appName: String? = null,
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

    private data class ServerAppInfo(
        val packageName: String?,
        val appName: String?,
    )

    private data class DeviceSelectionOptions(
        val serialId: String?,
        val useUsbDevice: Boolean,
        val useEmulator: Boolean,
    )

    private sealed interface DeviceSelectionResult {
        data class Success(val deviceIds: List<String>) : DeviceSelectionResult
        data class Failure(val message: String) : DeviceSelectionResult
    }

    private sealed interface ServerDiscoveryResult {
        data class Success(val servers: List<ServerRef>) : ServerDiscoveryResult
        data class Failure(val message: String) : ServerDiscoveryResult
    }

    private sealed interface ServerResolutionResult {
        data class Success(val server: ServerRef) : ServerResolutionResult
        data class Failure(val message: String) : ServerResolutionResult
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

    private abstract class DeviceScopedCommand(name: String) : CliktCommand(name = name) {
        protected val serialId by option(
            "-s",
            "--serial",
            help = "Use device with given serial",
        )
        protected val useUsbDevice by option(
            "-d",
            help = "Use the single connected USB device",
        ).flag(default = false)
        protected val useEmulator by option(
            "-e",
            help = "Use the single connected emulator",
        ).flag(default = false)

        protected fun deviceSelectionOptions(): DeviceSelectionOptions =
            DeviceSelectionOptions(
                serialId = serialId,
                useUsbDevice = useUsbDevice,
                useEmulator = useEmulator,
            )
    }

    private class NetworkListCommand(
        private val runtime: SnapOCli,
    ) : DeviceScopedCommand(name = "list") {
        override fun help(context: Context): String = "List available Snap-O link servers"

        private val noAppInfo by option(
            "--no-app-info",
            help = "Skip package and app metadata lookup",
        ).flag(default = false)
        private val json by option(
            "--json",
            help = "Emit machine-readable NDJSON",
        ).flag(default = false)

        override fun run() = runBlocking {
            val exitCode = runtime.runNetworkList(
                deviceSelection = deviceSelectionOptions(),
                includeAppInfo = !noAppInfo,
                outputMode = if (json) OutputMode.Json else OutputMode.Human,
            )
            if (exitCode != 0) throw ProgramResult(exitCode)
        }
    }

    private class NetworkRequestsCommand(
        private val runtime: SnapOCli,
    ) : DeviceScopedCommand(name = "requests") {
        override fun help(context: Context): String = "Emit CDP network events for a server"

        private val socketName by argument(
            name = "socket",
            help = "Snap-O socket name (e.g. snapo_server_12345)",
        )
        private val noStream by option(
            "--no-stream",
            help = "Emit only the buffered snapshot and then exit",
        ).flag(default = false)
        private val json by option(
            "--json",
            help = "Emit machine-readable NDJSON",
        ).flag(default = false)

        override fun run() = runBlocking {
            val exitCode = runtime.runNetworkRequests(
                deviceSelection = deviceSelectionOptions(),
                socketArgument = socketName,
                noStream = noStream,
                outputMode = if (json) OutputMode.Json else OutputMode.Human,
            )
            if (exitCode != 0) throw ProgramResult(exitCode)
        }
    }

    private class NetworkResponseBodyCommand(
        private val runtime: SnapOCli,
    ) : DeviceScopedCommand(name = "response-body") {
        override fun help(context: Context): String = "Fetch response body for a request id"

        private val socketName by argument(
            name = "socket",
            help = "Snap-O socket name (e.g. snapo_server_12345)",
        )
        private val requestId by option(
            "-r",
            "--request-id",
            help = "CDP request id",
        ).required()
        private val json by option(
            "--json",
            help = "Emit machine-readable NDJSON",
        ).flag(default = false)

        override fun run() = runBlocking {
            val exitCode = runtime.runNetworkResponseBody(
                deviceSelection = deviceSelectionOptions(),
                socketArgument = socketName,
                requestId = requestId,
                outputMode = if (json) OutputMode.Json else OutputMode.Human,
            )
            if (exitCode != 0) throw ProgramResult(exitCode)
        }
    }
}

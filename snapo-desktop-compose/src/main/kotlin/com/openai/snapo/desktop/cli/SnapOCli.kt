@file:Suppress("ImportOrdering")

package com.openai.snapo.desktop.cli

import com.github.ajalt.clikt.core.CliktCommand
import com.github.ajalt.clikt.core.Context
import com.github.ajalt.clikt.core.ProgramResult
import com.github.ajalt.clikt.core.main
import com.github.ajalt.clikt.core.subcommands
import com.github.ajalt.clikt.parameters.options.flag
import com.github.ajalt.clikt.parameters.options.option
import com.openai.snapo.desktop.adb.AdbExec
import com.openai.snapo.desktop.adb.AdbForwardHandle
import com.openai.snapo.desktop.inspector.decodeBodyForDisplay
import com.openai.snapo.desktop.link.SnapOLinkServerConnection
import com.openai.snapo.desktop.link.SnapORecord
import com.openai.snapo.desktop.protocol.CdpGetRequestPostDataParams
import com.openai.snapo.desktop.protocol.CdpGetRequestPostDataResult
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

@Suppress("LargeClass")
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
        socketArgument: String?,
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

    private suspend fun runNetworkShow(
        deviceSelection: DeviceSelectionOptions,
        socketArgument: String?,
        requestId: String,
        outputMode: OutputMode,
    ): Int {
        if (requestId.isBlank()) {
            printError("Please specify a request ID with -r/--request-id")
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

        return when (val result = fetchRequestDetails(adb, server, requestId)) {
            is FetchRequestDetailsResult.Success -> {
                emitRequestDetails(
                    line = CliRequestDetailsLine(
                        server = server.identifier,
                        requestId = requestId,
                        requestMethod = result.requestMethod,
                        requestUrl = result.requestUrl,
                        requestHeaders = result.requestHeaders,
                        requestBodyEncoding = result.requestBodyEncoding,
                        requestBody = result.requestBody,
                        responseStatus = result.responseStatus,
                        responseUrl = result.responseUrl,
                        responseHeaders = result.responseHeaders,
                        responseBody = result.responseBody,
                        responseBodyBase64Encoded = result.responseBodyBase64Encoded,
                    ),
                    outputMode = outputMode,
                )
                0
            }

            is FetchRequestDetailsResult.MissingBody -> {
                printError(result.message)
                1
            }

            is FetchRequestDetailsResult.Failure -> {
                printError(result.message)
                1
            }
        }
    }

    @Suppress("LongMethod", "CyclomaticComplexMethod", "NestedBlockDepth")
    private suspend fun fetchRequestDetails(
        adb: AdbExec,
        server: ServerRef,
        requestId: String,
    ): FetchRequestDetailsResult {
        val session = ServerSession(adb, server)
        val started = session.start()
        if (!started) {
            return FetchRequestDetailsResult.Failure("Failed to connect to ${server.identifier}")
        }

        return try {
            var featureOpened = false
            var commandId = 1
            var pendingRequestBodyId: Int? = null
            var pendingResponseBodyId: Int? = null
            var requestBodyAttempts = 0
            var responseBodyAttempts = 0
            val startedAtMs = System.currentTimeMillis()
            var details = RequestDetailsSnapshot()
            var requestBody: String? = null
            var requestBodyEncoding: String? = null
            var requestBodyResolved = false
            var responseBody: String? = null
            var responseBodyBase64Encoded = false
            var responseBodyResolved = false

            while (true) {
                val record = withTimeoutOrNull(CommandResponseTimeoutMs) {
                    session.events.receiveCatching().getOrNull()
                }

                when (record) {
                    null -> {
                        if (!featureOpened) {
                            val elapsed = System.currentTimeMillis() - startedAtMs
                            if (elapsed >= SnapshotMaxWaitMs) {
                                return FetchRequestDetailsResult.Failure(
                                    "Timed out waiting for handshake from ${server.identifier}"
                                )
                            }
                            continue
                        }
                        if (pendingRequestBodyId != null) pendingRequestBodyId = null
                        if (pendingResponseBodyId != null) pendingResponseBodyId = null
                    }

                    is SnapORecord.HelloRecord -> {
                        if (!featureOpened) {
                            session.sendFeatureOpened(NetworkFeatureId)
                            featureOpened = true
                        }
                    }

                    is SnapORecord.NetworkEvent -> {
                        val message = record.value
                        details = updateRequestDetailsSnapshot(details, message, requestId)
                        if (requestBodyEncoding == null) {
                            requestBodyEncoding = details.requestBodyEncoding
                        }
                        if (!requestBodyResolved && details.requestSeen && !details.requestHasPostData) {
                            requestBodyResolved = true
                        }
                        if (shouldResolveEmptyResponseBody(responseBodyResolved, details)) {
                            responseBody = ""
                            responseBodyBase64Encoded = false
                            responseBodyResolved = true
                        }
                        if (details.responseTerminal && !details.responseSeen) {
                            val failureMessage = details.loadingFailedMessage
                                ?: "Request failed before receiving a response for $requestId"
                            return FetchRequestDetailsResult.Failure(failureMessage)
                        }

                        val responseId = message.id
                        if (responseId != null && message.method == null) {
                            if (responseId == pendingRequestBodyId) {
                                pendingRequestBodyId = null
                                val error = message.error
                                if (error != null) {
                                    requestBodyResolved = true
                                } else {
                                    val parsedResult = message.result
                                        ?.let { result ->
                                            runCatching {
                                                Ndjson.decodeFromJsonElement(
                                                    CdpGetRequestPostDataResult.serializer(),
                                                    result,
                                                )
                                            }.getOrNull()
                                        }
                                    requestBody = parsedResult?.postData
                                    requestBodyResolved = true
                                }
                            } else if (responseId == pendingResponseBodyId) {
                                pendingResponseBodyId = null
                                val error = message.error
                                if (error != null) {
                                    val messageText = error.message
                                    return if (messageText.contains("No response body captured", ignoreCase = true)) {
                                        FetchRequestDetailsResult.MissingBody(messageText)
                                    } else {
                                        FetchRequestDetailsResult.Failure(messageText)
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
                                    ?: return FetchRequestDetailsResult.Failure(
                                        "Malformed response for Network.getResponseBody"
                                    )

                                responseBody = parsedResult.body
                                responseBodyBase64Encoded = parsedResult.base64Encoded
                                responseBodyResolved = true
                            }
                        }
                    }

                    else -> Unit
                }

                if (
                    shouldSendRequestBodyCommand(
                        featureOpened = featureOpened,
                        canRequestBody = details.requestSeen && details.requestHasPostData,
                        requestBodyResolved = requestBodyResolved,
                        pendingRequestBodyId = pendingRequestBodyId,
                        requestBodyAttempts = requestBodyAttempts,
                    )
                ) {
                    requestBodyAttempts += 1
                    pendingRequestBodyId = commandId
                    val requestBodyParams = Ndjson.encodeToJsonElement(
                        CdpGetRequestPostDataParams.serializer(),
                        CdpGetRequestPostDataParams(requestId = requestId),
                    )
                    val requestBodyCommand = CdpMessage(
                        id = commandId,
                        method = CdpNetworkMethod.GetRequestPostData,
                        params = requestBodyParams,
                    )
                    session.sendFeatureCommand(requestBodyCommand)
                    commandId += 1
                }

                if (
                    shouldSendResponseBodyCommand(
                        featureOpened = featureOpened,
                        canRequestBody = details.responseSeen &&
                            details.responseTerminal &&
                            !responseShouldNotHaveBody(details),
                        responseBodyResolved = responseBodyResolved,
                        pendingResponseBodyId = pendingResponseBodyId,
                        responseBodyAttempts = responseBodyAttempts,
                    )
                ) {
                    responseBodyAttempts += 1
                    pendingResponseBodyId = commandId
                    val responseBodyParams = Ndjson.encodeToJsonElement(
                        CdpGetResponseBodyParams.serializer(),
                        CdpGetResponseBodyParams(requestId = requestId),
                    )
                    val responseBodyCommand = CdpMessage(
                        id = commandId,
                        method = CdpNetworkMethod.GetResponseBody,
                        params = responseBodyParams,
                    )
                    session.sendFeatureCommand(responseBodyCommand)
                    commandId += 1
                }

                if (!requestBodyResolved &&
                    requestBodyAttempts >= CommandAttemptLimit &&
                    pendingRequestBodyId == null
                ) {
                    requestBodyResolved = true
                }

                if (!responseBodyResolved &&
                    responseBodyAttempts >= CommandAttemptLimit &&
                    pendingResponseBodyId == null
                ) {
                    return FetchRequestDetailsResult.Failure(
                        "Timed out waiting for Network.getResponseBody for $requestId on ${server.identifier}"
                    )
                }

                if (requestBodyResolved && responseBodyResolved) {
                    return FetchRequestDetailsResult.Success(
                        requestMethod = details.requestMethod,
                        requestUrl = details.requestUrl,
                        requestHeaders = details.requestHeaders,
                        requestBodyEncoding = requestBodyEncoding ?: details.requestBodyEncoding,
                        requestBody = requestBody,
                        responseStatus = details.responseStatus,
                        responseUrl = details.responseUrl,
                        responseHeaders = details.responseHeaders,
                        responseBody = responseBody.orEmpty(),
                        responseBodyBase64Encoded = responseBodyBase64Encoded,
                    )
                }

                if (System.currentTimeMillis() - startedAtMs >= SnapshotMaxWaitMs) {
                    return FetchRequestDetailsResult.Failure(
                        "Timed out waiting for network lifecycle for $requestId on ${server.identifier}"
                    )
                }
            }

            FetchRequestDetailsResult.Failure(
                "Timed out waiting for body details for $requestId on ${server.identifier}"
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
        socketArgument: String?,
        deviceSelection: DeviceSelectionOptions,
    ): ServerResolutionResult {
        val socketName = socketArgument?.trim()?.takeIf { it.isNotEmpty() }

        val discovery = discoverServers(adb, deviceSelection)
        val servers = when (discovery) {
            is ServerDiscoveryResult.Success -> discovery.servers
            is ServerDiscoveryResult.Failure -> return ServerResolutionResult.Failure(discovery.message)
        }
        if (servers.isEmpty()) {
            return ServerResolutionResult.Failure("No Snap-O link servers found for selected device(s)")
        }

        if (socketName == null) {
            return if (servers.size == 1) {
                ServerResolutionResult.Success(servers.first())
            } else {
                val socketList = formatSocketChoicesWithPackageHint(adb, servers)
                ServerResolutionResult.Failure(
                    "Multiple sockets found; select one with -n/--socket. Available: $socketList"
                )
            }
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
                val matchList = formatSocketChoicesWithPackageHint(adb, matches)
                ServerResolutionResult.Failure(
                    "Socket '$socketName' exists on multiple devices; use -s <serial>, -d, or -e. Available: $matchList"
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

    private suspend fun formatSocketChoicesWithPackageHint(
        adb: AdbExec,
        servers: List<ServerRef>,
    ): String {
        val entries = ArrayList<String>(servers.size)
        for (server in servers) {
            val packageName = packageNameHint(adb, server) ?: "unknown"
            entries.add("${server.socketName} (pkg:$packageName)")
        }
        return entries.joinToString(", ")
    }

    private fun shouldSendRequestBodyCommand(
        featureOpened: Boolean,
        canRequestBody: Boolean,
        requestBodyResolved: Boolean,
        pendingRequestBodyId: Int?,
        requestBodyAttempts: Int,
    ): Boolean {
        if (!featureOpened) return false
        if (!canRequestBody) return false
        if (requestBodyResolved) return false
        if (pendingRequestBodyId != null) return false
        return requestBodyAttempts < CommandAttemptLimit
    }

    private fun shouldSendResponseBodyCommand(
        featureOpened: Boolean,
        canRequestBody: Boolean,
        responseBodyResolved: Boolean,
        pendingResponseBodyId: Int?,
        responseBodyAttempts: Int,
    ): Boolean {
        if (!featureOpened) return false
        if (!canRequestBody) return false
        if (responseBodyResolved) return false
        if (pendingResponseBodyId != null) return false
        return responseBodyAttempts < CommandAttemptLimit
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

    private fun emitRequestDetails(line: CliRequestDetailsLine, outputMode: OutputMode) {
        when (outputMode) {
            OutputMode.Json -> printJson(line)
            OutputMode.Human -> {
                println("Server: ${line.server}")
                println("Request ID: ${line.requestId}")
                val requestMethod = line.requestMethod ?: "unknown"
                val requestUrl = line.requestUrl ?: "unknown"
                println("Request: $requestMethod $requestUrl")
                emitHeadersSection("Request Headers", line.requestHeaders)

                val responseStatus = line.responseStatus?.toString() ?: "unknown"
                val responseUrl = line.responseUrl ?: "unknown"
                println("Response: $responseStatus $responseUrl")
                emitHeadersSection("Response Headers", line.responseHeaders)

                println("Request Body:")
                println(
                    line.requestBody?.let { rawBody ->
                        decodeBodyForDisplay(
                            rawBody = rawBody,
                            rawEncoding = line.requestBodyEncoding,
                            contentEncodingHeader = line.requestHeaders
                                .entries
                                .firstOrNull { it.key.equals("Content-Encoding", ignoreCase = true) }
                                ?.value,
                        )
                    } ?: "<none>"
                )
                println("Response Body (base64 encoded: ${line.responseBodyBase64Encoded}):")
                println(line.responseBody)
            }
        }
    }

    private fun emitHeadersSection(title: String, headers: Map<String, String>) {
        println("$title:")
        if (headers.isEmpty()) {
            println("  <none>")
            return
        }
        headers.entries
            .sortedBy { it.key.lowercase() }
            .forEach { (name, value) ->
                println("  $name: $value")
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
    private data class CliRequestDetailsLine(
        val server: String,
        val requestId: String,
        val requestMethod: String? = null,
        val requestUrl: String? = null,
        val requestHeaders: Map<String, String> = emptyMap(),
        val requestBodyEncoding: String? = null,
        val requestBody: String? = null,
        val responseStatus: Int? = null,
        val responseUrl: String? = null,
        val responseHeaders: Map<String, String> = emptyMap(),
        val responseBody: String,
        val responseBodyBase64Encoded: Boolean,
    )

    private data class RequestDetailsSnapshot(
        val requestSeen: Boolean = false,
        val requestHasPostData: Boolean = false,
        val requestMethod: String? = null,
        val requestUrl: String? = null,
        val requestHeaders: Map<String, String> = emptyMap(),
        val requestBodyEncoding: String? = null,
        val responseSeen: Boolean = false,
        val responseTerminal: Boolean = false,
        val loadingFailedMessage: String? = null,
        val responseStatus: Int? = null,
        val responseUrl: String? = null,
        val responseHeaders: Map<String, String> = emptyMap(),
    )

    private fun updateRequestDetailsSnapshot(
        current: RequestDetailsSnapshot,
        message: CdpMessage,
        requestId: String,
    ): RequestDetailsSnapshot {
        return when (message.method) {
            CdpNetworkMethod.RequestWillBeSent -> updateSnapshotForRequest(current, message, requestId)
            CdpNetworkMethod.ResponseReceived -> updateSnapshotForResponse(current, message, requestId)
            CdpNetworkMethod.LoadingFinished -> updateSnapshotForLoadingFinished(current, message, requestId)
            CdpNetworkMethod.LoadingFailed -> updateSnapshotForLoadingFailed(current, message, requestId)

            else -> current
        }
    }

    private fun updateSnapshotForRequest(
        current: RequestDetailsSnapshot,
        message: CdpMessage,
        requestId: String,
    ): RequestDetailsSnapshot {
        val params = decodeParams<CdpRequestWillBeSentParams>(message) ?: return current
        if (params.requestId != requestId) return current
        return current.copy(
            requestSeen = true,
            requestHasPostData = params.request.hasPostData,
            requestMethod = params.request.method,
            requestUrl = params.request.url,
            requestHeaders = redactHeaderMap(params.request.headers, requestHeaderNames),
            requestBodyEncoding = params.request.postDataEncoding,
        )
    }

    private fun updateSnapshotForResponse(
        current: RequestDetailsSnapshot,
        message: CdpMessage,
        requestId: String,
    ): RequestDetailsSnapshot {
        val params = decodeParams<CdpResponseReceivedParams>(message) ?: return current
        if (params.requestId != requestId) return current
        return current.copy(
            responseSeen = true,
            responseStatus = params.response.status,
            responseUrl = params.response.url,
            responseHeaders = redactHeaderMap(params.response.headers, responseHeaderNames),
        )
    }

    private fun updateSnapshotForLoadingFinished(
        current: RequestDetailsSnapshot,
        message: CdpMessage,
        requestId: String,
    ): RequestDetailsSnapshot {
        val params = decodeParams<CdpLoadingFinishedParams>(message) ?: return current
        if (params.requestId != requestId) return current
        return current.copy(
            responseTerminal = true,
            loadingFailedMessage = null,
        )
    }

    private fun updateSnapshotForLoadingFailed(
        current: RequestDetailsSnapshot,
        message: CdpMessage,
        requestId: String,
    ): RequestDetailsSnapshot {
        val params = decodeParams<CdpLoadingFailedParams>(message) ?: return current
        if (params.requestId != requestId) return current
        return current.copy(
            responseTerminal = true,
            loadingFailedMessage = params.errorText ?: params.type,
        )
    }

    private fun responseShouldNotHaveBody(snapshot: RequestDetailsSnapshot): Boolean {
        if (snapshot.requestMethod.equals("HEAD", ignoreCase = true)) return true
        val status = snapshot.responseStatus ?: return false
        if (status in 100..199 || status == 204 || status == 304) return true
        val contentLength = snapshot.responseHeaders.entries
            .firstOrNull { (name, _) -> name.equals("Content-Length", ignoreCase = true) }
            ?.value
            ?.trim()
            ?.toLongOrNull()
        return contentLength == 0L
    }

    private fun shouldResolveEmptyResponseBody(
        responseBodyResolved: Boolean,
        details: RequestDetailsSnapshot,
    ): Boolean {
        if (responseBodyResolved) return false
        if (!details.responseSeen) return false
        if (!details.responseTerminal) return false
        return responseShouldNotHaveBody(details)
    }

    private fun redactHeaderMap(
        headers: Map<String, String>,
        sensitiveHeaderNames: Set<String>,
    ): Map<String, String> {
        if (headers.isEmpty()) return headers
        var changed = false
        val updated = LinkedHashMap<String, String>(headers.size)
        headers.forEach { (name, value) ->
            if (sensitiveHeaderNames.any { sensitive -> sensitive.equals(name, ignoreCase = true) }) {
                updated[name] = RedactedValue
                changed = true
            } else {
                updated[name] = value
            }
        }
        return if (changed) updated else headers
    }

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

    private sealed interface FetchRequestDetailsResult {
        data class Success(
            val requestMethod: String?,
            val requestUrl: String?,
            val requestHeaders: Map<String, String>,
            val requestBodyEncoding: String?,
            val requestBody: String?,
            val responseStatus: Int?,
            val responseUrl: String?,
            val responseHeaders: Map<String, String>,
            val responseBody: String,
            val responseBodyBase64Encoded: Boolean,
        ) : FetchRequestDetailsResult

        data class MissingBody(
            val message: String,
        ) : FetchRequestDetailsResult

        data class Failure(
            val message: String,
        ) : FetchRequestDetailsResult
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
                NetworkShowCommand(runtime),
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

        private val socketName by option(
            "-n",
            "--socket",
            help = "Snap-O socket name (e.g. snapo_server_12345). Optional if only one is available",
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

    private class NetworkShowCommand(
        private val runtime: SnapOCli,
    ) : DeviceScopedCommand(name = "show") {
        override fun help(
            context: Context
        ): String = "Show details for a request id (headers + request/response bodies)"

        private val socketName by option(
            "-n",
            "--socket",
            help = "Snap-O socket name (e.g. snapo_server_12345). Optional if only one is available",
        )
        private val requestId by option(
            "-r",
            "--request-id",
            help = "CDP request id (required)",
        )
        private val json by option(
            "--json",
            help = "Emit machine-readable NDJSON",
        ).flag(default = false)

        override fun run() = runBlocking {
            val exitCode = runtime.runNetworkShow(
                deviceSelection = deviceSelectionOptions(),
                socketArgument = socketName,
                requestId = requestId.orEmpty(),
                outputMode = if (json) OutputMode.Json else OutputMode.Human,
            )
            if (exitCode != 0) throw ProgramResult(exitCode)
        }
    }
}

package com.openai.snapo.tweaks.internal

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.JsonReader
import android.util.JsonToken
import android.util.JsonWriter
import com.openai.snapo.tweaks.TweakColorValue
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.StringWriter
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.concurrent.thread

private const val MaxHeaderBytes = 16 * 1024
private const val MaxBodyBytes = 64 * 1024
private const val SocketTimeoutMillis = 5_000
private const val MainThreadTimeoutMillis = 5_000L
private const val MaximumConcurrentConnections = 32
private const val EventHeartbeatSeconds = 15L

internal class TweakHttpServer(
    private val appInfoProvider: TweakAppInfoProvider,
    private val socketName: String = "snapo_tweaks_${Process.myPid()}",
    private val mainHandler: Handler = Handler(Looper.getMainLooper()),
) : Closeable {
    private val lifecycleLock = Any()
    private val connectionPermits = Semaphore(MaximumConcurrentConnections)
    private val activeSockets = LinkedHashSet<LocalSocket>()
    private val changePublisher = TweakChangePublisher(mainHandler::post)

    @Volatile
    private var running = false

    private var server: LocalServerSocket? = null
    private var acceptThread: Thread? = null
    private var registryObserver: Closeable? = null

    fun start() {
        synchronized(lifecycleLock) {
            if (running) return

            val localServer = LocalServerSocket(socketName)
            server = localServer
            running = true
            registryObserver = TweakRegistry.observeChanges(changePublisher::notifyChanged)
            acceptThread = thread(
                isDaemon = true,
                name = "Snap-O Tweaks",
            ) {
                acceptConnections(localServer)
            }
        }
    }

    override fun close() {
        val sockets = synchronized(lifecycleLock) {
            running = false
            runCatching { server?.close() }
            server = null
            acceptThread?.interrupt()
            acceptThread = null
            registryObserver?.close()
            registryObserver = null
            changePublisher.close()
            activeSockets.toList().also { activeSockets.clear() }
        }
        sockets.forEach { socket -> runCatching { socket.close() } }
    }

    private fun acceptConnections(localServer: LocalServerSocket) {
        while (running) {
            val socket = try {
                localServer.accept()
            } catch (_: IOException) {
                if (!running) return
                continue
            }

            handleAcceptedConnection(socket)
        }
    }

    private fun handleAcceptedConnection(socket: LocalSocket) {
        if (!connectionPermits.tryAcquire()) {
            runCatching {
                socket.use {
                    writeResponse(
                        it.outputStream,
                        errorResponse(503, "Too many active tweak connections."),
                    )
                }
            }
            return
        }

        synchronized(lifecycleLock) { activeSockets.add(socket) }
        thread(isDaemon = true, name = "Snap-O Tweaks connection") {
            try {
                runCatching { socket.use(::handleConnection) }
            } finally {
                synchronized(lifecycleLock) { activeSockets.remove(socket) }
                connectionPermits.release()
            }
        }
    }

    private fun handleConnection(socket: LocalSocket) {
        socket.soTimeout = SocketTimeoutMillis

        val response = try {
            val request = readRequest(socket.inputStream)
            if (request.path == "/tweaks/events" && request.method == "GET") {
                streamTweaks(socket.outputStream)
                return
            }
            route(request)
        } catch (error: TweakUpdateException) {
            errorResponse(error.statusCode, error.message ?: "Invalid tweak update.")
        } catch (error: HttpFailure) {
            errorResponse(error.statusCode, error.message, error.allowedMethods)
        } catch (_: SocketTimeoutException) {
            errorResponse(408, "The request timed out.")
        } catch (_: IOException) {
            errorResponse(400, "Malformed HTTP or JSON request.")
        } catch (_: IllegalStateException) {
            errorResponse(400, "Malformed JSON request.")
        } catch (_: NumberFormatException) {
            errorResponse(400, "Malformed JSON number.")
        }

        writeResponse(socket.outputStream, response)
    }

    private fun route(request: HttpRequest): HttpResponse = when (request.path) {
        "/app" -> routeApp(request)
        "/app/icon" -> routeAppIcon(request)
        "/tweaks", "/tweaks?include=adjusted" -> routeTweaks(request)
        "/tweaks/events" -> throw HttpFailure(
            statusCode = 405,
            message = "Unsupported method: ${request.method}",
            allowedMethods = "GET",
        )
        else -> throw HttpFailure(404, "Unknown endpoint: ${request.path}")
    }

    private fun streamTweaks(output: OutputStream) {
        changePublisher.subscribe().use { subscription ->
            output.write(
                (
                    "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: text/event-stream; charset=utf-8\r\n" +
                        "Cache-Control: no-cache\r\n" +
                        "Connection: close\r\n\r\n"
                    ).toByteArray(StandardCharsets.US_ASCII),
            )
            writeTweakEvent(output, subscription.initial)

            while (running) {
                val snapshot = try {
                    subscription.events.poll(EventHeartbeatSeconds, TimeUnit.SECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }

                if (snapshot == null) {
                    output.write(": keep-alive\n\n".toByteArray(StandardCharsets.US_ASCII))
                    output.flush()
                } else {
                    writeTweakEvent(output, snapshot)
                }
            }
        }
    }

    private fun writeTweakEvent(output: OutputStream, tweaks: List<TweakSnapshot>) {
        output.write("event: tweaks\ndata: ".toByteArray(StandardCharsets.US_ASCII))
        output.write(tweaksResponse(tweaks, includeDescriptors = true).body)
        output.write("\n\n".toByteArray(StandardCharsets.US_ASCII))
        output.flush()
    }

    private fun routeApp(request: HttpRequest): HttpResponse {
        if (request.method != "GET") {
            throw HttpFailure(
                statusCode = 405,
                message = "Unsupported method: ${request.method}",
                allowedMethods = "GET",
            )
        }

        return appInfoResponse(appInfoProvider.load())
    }

    private fun routeAppIcon(request: HttpRequest): HttpResponse {
        if (request.method != "GET") {
            throw HttpFailure(
                statusCode = 405,
                message = "Unsupported method: ${request.method}",
                allowedMethods = "GET",
            )
        }

        val icon = appInfoProvider.loadIcon()
            ?: throw HttpFailure(404, "Application icon is unavailable.")

        return HttpResponse(
            statusCode = 200,
            body = icon,
            contentType = "image/png",
        )
    }

    private fun routeTweaks(request: HttpRequest): HttpResponse = when (request.method) {
        "GET" -> tweaksResponse(
            TweakRegistry.snapshot(includeAdjusted = request.path != "/tweaks"),
            includeDescriptors = true,
        )
        "PATCH" -> {
            requireJsonRequest(request)
            val changes = readPatchValues(request.body)
            tweaksResponse(updateOnMainThread(changes), includeDescriptors = false)
        }

        else -> throw HttpFailure(
            statusCode = 405,
            message = "Unsupported method: ${request.method}",
            allowedMethods = "GET, PATCH",
        )
    }

    private fun readRequest(input: InputStream): HttpRequest {
        val firstLine = readLine(input)
        val parts = firstLine.split(' ')
        if (parts.size != 3 || parts[2] !in listOf("HTTP/1.0", "HTTP/1.1")) {
            throw HttpFailure(400, "Malformed HTTP request line.")
        }

        val headers = readHeaders(input, firstLine.length)
        val contentLength = readContentLength(headers)
        val body = readBody(input, contentLength)
        val target = parts[1]
        if ('?' in target && (target != "/tweaks?include=adjusted" || parts[0] != "GET")) {
            invalidRequest("Unsupported query parameters.")
        }

        return HttpRequest(
            method = parts[0],
            path = target,
            headers = headers,
            body = body,
        )
    }

    private fun readHeaders(input: InputStream, requestLineBytes: Int): Map<String, String> {
        val headers = LinkedHashMap<String, String>()
        var totalBytes = requestLineBytes

        while (true) {
            val line = readLine(input)
            totalBytes += line.length + 2
            if (totalBytes > MaxHeaderBytes) {
                invalidRequest("HTTP headers are too large.")
            }
            if (line.isEmpty()) return headers

            val separator = line.indexOf(':')
            if (separator <= 0) {
                invalidRequest("Malformed HTTP header.")
            }

            val name = line.substring(0, separator).trim().lowercase(Locale.ROOT)
            val value = line.substring(separator + 1).trim()
            if (headers.put(name, value) != null && name == "content-length") {
                invalidRequest("Duplicate Content-Length header.")
            }
        }
    }

    private fun readLine(input: InputStream): String {
        val buffer = ByteArrayOutputStream()

        while (true) {
            val next = input.read()
            if (next == -1) {
                throw HttpFailure(400, "Incomplete HTTP request.")
            }
            if (next == '\n'.code) break
            if (buffer.size() >= MaxHeaderBytes) {
                throw HttpFailure(400, "HTTP request line is too large.")
            }
            buffer.write(next)
        }

        return buffer.toString(StandardCharsets.ISO_8859_1.name()).removeSuffix("\r")
    }

    private fun readContentLength(headers: Map<String, String>): Int {
        if (headers.containsKey("transfer-encoding")) {
            invalidRequest("Transfer-Encoding is unsupported.")
        }

        val rawLength = headers["content-length"] ?: return 0
        val contentLength = rawLength.toIntOrNull()
            ?: invalidRequest("Invalid Content-Length header.")
        if (contentLength < 0) {
            invalidRequest("Content-Length cannot be negative.")
        }
        if (contentLength > MaxBodyBytes) {
            throw HttpFailure(413, "The request body is too large.")
        }

        return contentLength
    }

    private fun readBody(input: InputStream, contentLength: Int): ByteArray {
        val body = ByteArray(contentLength)
        var position = 0

        while (position < contentLength) {
            val count = input.read(body, position, contentLength - position)
            if (count < 0) {
                throw HttpFailure(400, "Incomplete HTTP request body.")
            }
            position += count
        }

        return body
    }

    private fun requireJsonRequest(request: HttpRequest) {
        if (request.body.isEmpty()) {
            throw HttpFailure(400, "PATCH requires a JSON request body.")
        }

        val contentType = request.headers["content-type"]
        if (contentType != null &&
            !contentType.substringBefore(';').trim().equals("application/json", ignoreCase = true)
        ) {
            throw HttpFailure(400, "PATCH requires application/json.")
        }
    }

    private fun readPatchValues(body: ByteArray): Map<String, Any?> {
        val values = LinkedHashMap<String, Any?>()

        JsonReader(InputStreamReader(ByteArrayInputStream(body), StandardCharsets.UTF_8)).use { reader ->
            reader.beginObject()
            if (!reader.hasNext() || reader.nextName() != "values") {
                invalidRequest("PATCH must contain a values object.")
            }

            readTweakValues(reader, values)
            if (reader.hasNext()) {
                invalidRequest("PATCH must contain exactly one values object.")
            }
            reader.endObject()
            if (reader.peek() != JsonToken.END_DOCUMENT) {
                invalidRequest("Unexpected content after the JSON request.")
            }
        }

        return values
    }

    private fun readTweakValues(
        reader: JsonReader,
        values: MutableMap<String, Any?>,
    ) {
        reader.beginObject()

        while (reader.hasNext()) {
            val name = reader.nextName()
            if (values.containsKey(name)) {
                invalidRequest("Duplicate tweak: $name")
            }
            values[name] = readJsonValue(reader)
        }

        reader.endObject()
    }

    private fun readJsonValue(reader: JsonReader): Any? = when (reader.peek()) {
        JsonToken.STRING -> reader.nextString()
        JsonToken.NUMBER -> TweakNumbers.parse(reader.nextString())
        JsonToken.BOOLEAN -> reader.nextBoolean()
        JsonToken.NULL -> {
            reader.nextNull()
            null
        }

        else -> throw HttpFailure(422, "Tweak values must be primitive JSON values.")
    }

    private fun updateOnMainThread(values: Map<String, Any?>): List<TweakSnapshot> {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return TweakRegistry.update(values)
        }

        val update = FutureTask { TweakRegistry.update(values) }
        if (!mainHandler.post(update)) {
            throw HttpFailure(503, "The Android main thread is unavailable.")
        }

        return awaitUpdate(update)
    }

    private fun awaitUpdate(update: FutureTask<List<TweakSnapshot>>): List<TweakSnapshot> =
        try {
            update.get(MainThreadTimeoutMillis, TimeUnit.MILLISECONDS)
        } catch (error: ExecutionException) {
            throw updateFailure(error)
        } catch (_: TimeoutException) {
            update.cancel(false)
            throw HttpFailure(504, "The tweak update timed out.")
        } catch (_: InterruptedException) {
            update.cancel(false)
            Thread.currentThread().interrupt()
            throw HttpFailure(503, "The tweak update was interrupted.")
        }

    private fun updateFailure(error: ExecutionException): Exception {
        val cause = error.cause

        return if (cause is TweakUpdateException) {
            cause
        } else {
            HttpFailure(500, "The tweak update could not be applied.", error)
        }
    }

    private fun appInfoResponse(appInfo: TweakAppInfo): HttpResponse {
        val output = StringWriter()
        JsonWriter(output).use { writer ->
            writer.beginObject()
            writer.name("name").value(appInfo.name)
            writer.name("packageName").value(appInfo.packageName)
            writer.endObject()
        }

        return HttpResponse(200, output.toString().toByteArray(StandardCharsets.UTF_8))
    }

    private fun tweaksResponse(
        tweaks: List<TweakSnapshot>,
        includeDescriptors: Boolean,
    ): HttpResponse {
        val output = StringWriter()
        JsonWriter(output).use { writer ->
            writer.beginObject()
            writer.name("tweaks").beginArray()

            tweaks.forEach { tweak ->
                writeTweak(writer, tweak, includeDescriptors)
            }

            writer.endArray()
            writer.endObject()
        }

        return HttpResponse(200, output.toString().toByteArray(StandardCharsets.UTF_8))
    }

    private fun writeTweak(
        writer: JsonWriter,
        tweak: TweakSnapshot,
        includeDescriptor: Boolean,
    ) {
        writer.beginObject()
        writer.name("name").value(tweak.descriptor.name)

        if (includeDescriptor) {
            writer.name("type").value(tweak.descriptor.type.wireName)
            writer.name("default")
            writeJsonValue(writer, tweak.descriptor.default)
        }

        writer.name("value")
        writeJsonValue(writer, tweak.value)

        if (includeDescriptor) {
            writeConstraints(writer, tweak.descriptor)
        }

        writer.endObject()
    }

    private fun writeConstraints(writer: JsonWriter, descriptor: TweakDescriptor) {
        descriptor.min?.let { minimum -> writer.name("min").value(minimum) }
        descriptor.max?.let { maximum -> writer.name("max").value(maximum) }
        descriptor.step?.let { increment -> writer.name("step").value(increment) }
    }

    private fun writeJsonValue(writer: JsonWriter, value: Any) {
        when (value) {
            is Boolean -> writer.value(value)
            is Number -> writer.value(value)
            is String -> writer.value(value)
            is TweakColorValue -> writer.value(value.wireValue)
            else -> throw HttpFailure(500, "Unsupported tweak value.")
        }
    }

    private fun errorResponse(
        statusCode: Int,
        message: String,
        allowedMethods: String? = null,
    ): HttpResponse {
        val output = StringWriter()
        JsonWriter(output).use { writer ->
            writer.beginObject()
            writer.name("error").value(message)
            writer.endObject()
        }

        return HttpResponse(
            statusCode,
            output.toString().toByteArray(StandardCharsets.UTF_8),
            allowedMethods,
        )
    }

    private fun writeResponse(output: OutputStream, response: HttpResponse) {
        val reason = reasonPhrase(response.statusCode)
        val headers = buildString {
            append("HTTP/1.1 ${response.statusCode} $reason\r\n")
            append("Content-Type: ${response.contentType}\r\n")
            append("Content-Length: ${response.body.size}\r\n")
            if (response.allowedMethods != null) {
                append("Allow: ${response.allowedMethods}\r\n")
            }
            append("Connection: close\r\n\r\n")
        }

        output.write(headers.toByteArray(StandardCharsets.US_ASCII))
        output.write(response.body)
        output.flush()
    }

    private fun reasonPhrase(statusCode: Int): String = when (statusCode) {
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        408 -> "Request Timeout"
        413 -> "Payload Too Large"
        422 -> "Unprocessable Entity"
        500 -> "Internal Server Error"
        503 -> "Service Unavailable"
        504 -> "Gateway Timeout"
        else -> "Error"
    }

    private data class HttpRequest(
        val method: String,
        val path: String,
        val headers: Map<String, String>,
        val body: ByteArray,
    )

    private data class HttpResponse(
        val statusCode: Int,
        val body: ByteArray,
        val allowedMethods: String? = null,
        val contentType: String = "application/json; charset=utf-8",
    )

    private class HttpFailure(
        val statusCode: Int,
        override val message: String,
        cause: Throwable? = null,
        val allowedMethods: String? = null,
    ) : Exception(message, cause)

    private fun invalidRequest(message: String): Nothing =
        throw HttpFailure(400, message)
}

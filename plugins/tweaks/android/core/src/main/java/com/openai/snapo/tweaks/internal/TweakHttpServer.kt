package com.openai.snapo.tweaks.internal

import android.os.Handler
import android.os.Looper
import android.util.JsonReader
import android.util.JsonToken
import android.util.JsonWriter
import com.openai.snapo.plugin.PluginCall
import com.openai.snapo.plugin.PluginHttpRequestPolicy
import com.openai.snapo.plugin.PluginServer
import com.openai.snapo.plugin.PluginSseSession
import com.openai.snapo.tweaks.BezierCurve
import com.openai.snapo.tweaks.TweakColorValue
import com.openai.snapo.tweaks.core.SnapOPlugin
import kotlinx.coroutines.isActive
import kotlinx.coroutines.runInterruptible
import java.io.ByteArrayInputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStreamReader
import java.io.StringWriter
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import com.openai.snapo.plugin.PluginHttpException as HttpFailure
import com.openai.snapo.plugin.PluginHttpRequest as HttpRequest
import com.openai.snapo.plugin.PluginHttpResponse as HttpResponse

internal data class TweakBatchError(
    val name: String,
    val error: String,
)

internal data class TweakBatchResult(
    val tweaks: List<TweakSnapshot>,
    val errors: List<TweakBatchError>,
)

internal fun applyTweakBatch(
    values: Map<String, Any?>,
    update: (Map<String, Any?>) -> List<TweakSnapshot> = TweakRegistry::update,
): TweakBatchResult {
    val tweaks = ArrayList<TweakSnapshot>(values.size)
    val errors = ArrayList<TweakBatchError>()

    values.forEach { (name, value) ->
        try {
            tweaks.add(update(mapOf(name to value)).single())
        } catch (failure: TweakUpdateException) {
            errors.add(TweakBatchError(name, failure.message ?: "Invalid tweak update."))
        } catch (_: Exception) {
            errors.add(TweakBatchError(name, "The tweak could not be updated."))
        }
    }

    return TweakBatchResult(tweaks, errors)
}

private const val MaxBodyBytes = 64 * 1024
private const val MainThreadTimeoutMillis = 5_000L

internal class TweakHttpServer(
    private val mainHandler: Handler = Handler(Looper.getMainLooper()),
) : Closeable {
    private val lifecycleLock = Any()
    private val changePublisher = TweakChangePublisher(
        schedule = mainHandler::post,
        snapshot = {
            TweakRegistry.snapshot(
                cachedOnly = Looper.myLooper() != Looper.getMainLooper(),
            )
        },
    )

    private val server = PluginServer(SnapOPlugin.ID) {
        requestPolicy = RequestPolicy
        preflightStatusCode = 200
        cacheControl = "no-cache"
        validateRequest { request ->
            if ('?' in request.requestTarget &&
                (request.requestTarget != "/tweaks?include=adjusted" || request.method != "GET")
            ) {
                invalidRequest("Unsupported query parameters.")
            }
        }
        onError { error ->
            when (error) {
                is TweakUpdateException -> errorResponse(error.statusCode, error.message ?: "Invalid tweak update.")
                is HttpFailure -> errorResponse(error.statusCode, error.message, error.allowedMethods)
                is SocketTimeoutException -> errorResponse(408, "The request timed out.")
                is IOException, is IllegalArgumentException -> errorResponse(400, "Malformed HTTP or JSON request.")
                is IllegalStateException -> errorResponse(400, "Malformed JSON request.")
                else -> errorResponse(500, "The request could not be completed.")
            }
        }
        get("/tweaks") {
            respond(
                runInterruptible {
                    tweaksResponse(
                        snapshotForRequest(includeAdjusted = request.requestTarget != "/tweaks"),
                        includeDescriptors = true,
                    )
                }
            )
        }
        patch("/tweaks") {
            requireJsonRequest(request)
            val result = runInterruptible { updateOnMainThread(readPatchValues(request.body)) }
            respond(tweaksResponse(result.tweaks, includeDescriptors = false, errors = result.errors))
        }
        post("/tweaks/action") {
            requireJsonRequest(request)
            val name = readActionName(request.body)
            runInterruptible { invokeActionOnMainThread(name) }
            respond(actionResponse(name))
        }
        get("/tweaks/events") { streamTweaks() }
    }
    private var registryObserver: Closeable? = null

    fun start() {
        synchronized(lifecycleLock) {
            if (server.isRunning) return
            val observer = TweakRegistry.observeChanges(changePublisher::notifyChanged)
            try {
                server.start()
                registryObserver = observer
            } catch (failure: IOException) {
                observer.close()
                throw failure
            }
        }
    }

    override fun close() {
        synchronized(lifecycleLock) {
            server.close()
            registryObserver?.close()
            registryObserver = null
            changePublisher.close()
        }
    }

    private suspend fun PluginCall.streamTweaks() {
        val subscription = runInterruptible {
            try {
                changePublisher.subscribe()
            } catch (_: UninitializedTweakSnapshotException) {
                runOnMainThread("snapshot", "loaded", changePublisher::subscribe)
            }
        }
        subscription.use {
            // Tweaks protocol 7 uses a close-delimited SSE response.
            respondSse(chunked = false) {
                sendTweaks(subscription.initial)
                while (isActive) {
                    sendTweaks(runInterruptible { subscription.events.take() })
                }
            }
        }
    }

    private fun PluginSseSession.sendTweaks(tweaks: List<TweakSnapshot>) {
        val json = tweaksResponse(tweaks, includeDescriptors = true).body.toString(StandardCharsets.UTF_8)
        send(json, event = "tweaks")
    }

    private fun requireJsonRequest(request: HttpRequest) {
        if (request.body.isEmpty()) {
            throw HttpFailure(400, "${request.method} requires a JSON request body.")
        }

        val contentType = request.headers["content-type"]
        if (contentType != null &&
            !contentType.substringBefore(';').trim().equals("application/json", ignoreCase = true)
        ) {
            throw HttpFailure(400, "${request.method} requires application/json.")
        }
    }

    private fun readActionName(body: ByteArray): String {
        JsonReader(InputStreamReader(ByteArrayInputStream(body), StandardCharsets.UTF_8)).use { reader ->
            reader.beginObject()
            if (!reader.hasNext() || reader.nextName() != "name" || reader.peek() != JsonToken.STRING) {
                invalidRequest("POST must contain exactly one action name string.")
            }
            val name = reader.nextString()
            if (name.isBlank() || reader.hasNext()) {
                invalidRequest("POST must contain exactly one non-blank action name string.")
            }
            reader.endObject()
            if (reader.peek() != JsonToken.END_DOCUMENT) {
                invalidRequest("Unexpected content after the JSON request.")
            }
            return name
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
        JsonToken.BEGIN_OBJECT -> readCoordinateObject(reader)
        JsonToken.STRING -> reader.nextString()
        JsonToken.NUMBER -> TweakNumbers.parse(reader.nextString())
        JsonToken.BOOLEAN -> reader.nextBoolean()
        JsonToken.NULL -> {
            reader.nextNull()
            null
        }

        else -> throw HttpFailure(422, "Tweak values must be primitives or coordinate objects.")
    }

    private fun readCoordinateObject(reader: JsonReader): Map<String, Any?> {
        val coordinates = linkedMapOf<String, Any?>()
        reader.beginObject()
        while (reader.hasNext()) {
            val key = reader.nextName()
            if (coordinates.containsKey(key)) invalidRequest("Duplicate coordinate: $key")
            if (coordinates.size >= 4) throw HttpFailure(422, "A curve must contain exactly four coordinates.")
            if (reader.peek() == JsonToken.BEGIN_OBJECT || reader.peek() == JsonToken.BEGIN_ARRAY) {
                throw HttpFailure(422, "Curve coordinates must be numbers.")
            }
            coordinates[key] = readJsonValue(reader)
        }
        reader.endObject()
        return coordinates
    }

    private fun updateOnMainThread(values: Map<String, Any?>): TweakBatchResult =
        runOnMainThread("update", "applied") { applyTweakBatch(values) }

    private fun snapshotForRequest(includeAdjusted: Boolean): List<TweakSnapshot> = try {
        TweakRegistry.snapshot(includeAdjusted = includeAdjusted, cachedOnly = true)
    } catch (_: UninitializedTweakSnapshotException) {
        runOnMainThread("snapshot", "loaded") {
            TweakRegistry.snapshot(includeAdjusted = includeAdjusted)
        }
    }

    private fun invokeActionOnMainThread(name: String) =
        runOnMainThread("action", "invoked") { TweakRegistry.invokeAction(name) }

    private fun <T> runOnMainThread(
        operationName: String,
        failureVerb: String,
        operation: () -> T,
    ): T {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return operation()
        }

        val task = FutureTask { operation() }
        if (!mainHandler.post(task)) {
            throw HttpFailure(503, "The Android main thread is unavailable.")
        }

        val failure = try {
            return task.get(MainThreadTimeoutMillis, TimeUnit.MILLISECONDS)
        } catch (error: ExecutionException) {
            error.cause as? TweakUpdateException
                ?: HttpFailure(500, "The tweak $operationName could not be $failureVerb.", error)
        } catch (error: TimeoutException) {
            task.cancel(false)
            HttpFailure(504, "The tweak $operationName timed out.", error)
        } catch (error: InterruptedException) {
            task.cancel(false)
            Thread.currentThread().interrupt()
            HttpFailure(503, "The tweak $operationName was interrupted.", error)
        }

        throw failure
    }

    private fun tweaksResponse(
        tweaks: List<TweakSnapshot>,
        includeDescriptors: Boolean,
        errors: List<TweakBatchError> = emptyList(),
    ): HttpResponse {
        val output = StringWriter()
        JsonWriter(output).use { writer ->
            writer.beginObject()
            writer.name("tweaks").beginArray()

            tweaks.forEach { tweak ->
                writeTweak(writer, tweak, includeDescriptors)
            }

            writer.endArray()
            if (errors.isNotEmpty()) {
                writer.name("errors").beginArray()
                errors.forEach { error ->
                    writer.beginObject()
                    writer.name("name").value(error.name)
                    writer.name("error").value(error.error)
                    writer.endObject()
                }
                writer.endArray()
            }
            writer.endObject()
        }

        return HttpResponse(200, output.toString().toByteArray(StandardCharsets.UTF_8))
    }

    private fun actionResponse(name: String): HttpResponse {
        val output = StringWriter()
        JsonWriter(output).use { writer ->
            writer.beginObject()
            writer.name("name").value(name)
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
            if (tweak.descriptor.type != TweakType.ACTION) {
                writer.name("default")
                writeJsonValue(writer, tweak.descriptor.default)
            }
            if ((tweak.value as? TweakActionValue)?.conflicted == true) {
                writer.name("conflicted").value(true)
            }
        }

        if (tweak.descriptor.type != TweakType.ACTION) {
            writer.name("value")
            writeJsonValue(writer, tweak.value)
            if (tweak.modified) {
                writer.name("modified").value(true)
            }
        }

        if (includeDescriptor) {
            writeConstraints(writer, tweak.descriptor)
            writeOptions(writer, tweak.descriptor)
        }

        writer.endObject()
    }

    private fun writeConstraints(writer: JsonWriter, descriptor: TweakDescriptor) {
        descriptor.min?.let { minimum -> writer.name("min").value(minimum) }
        descriptor.max?.let { maximum -> writer.name("max").value(maximum) }
        descriptor.step?.let { increment -> writer.name("step").value(increment) }
    }

    private fun writeOptions(writer: JsonWriter, descriptor: TweakDescriptor) {
        if (descriptor.type != TweakType.ENUM) return

        writer.name("options").beginArray()
        descriptor.options.forEach { option ->
            writer.value(option)
        }
        writer.endArray()
    }

    private fun writeJsonValue(writer: JsonWriter, value: Any) {
        when (value) {
            is Boolean -> writer.value(value)
            is Number -> writer.value(value)
            is String -> writer.value(value)
            is TweakColorValue -> writer.value(value.wireValue)
            is BezierCurve -> {
                writer.beginObject()
                writer.name("x1").value(value.x1)
                writer.name("y1").value(value.y1)
                writer.name("x2").value(value.x2)
                writer.name("y2").value(value.y2)
                writer.endObject()
            }
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

    private fun invalidRequest(message: String): Nothing =
        throw HttpFailure(400, message)
}

private val RequestPolicy = PluginHttpRequestPolicy(
    maxBodyBytes = MaxBodyBytes,
    httpVersions = setOf("HTTP/1.0", "HTTP/1.1"),
    requireJsonContentType = false,
)

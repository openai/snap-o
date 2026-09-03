package com.openai.snapo.demo.httpurlconnection

import com.openai.snapo.demo.shared.tasks.CreateTask
import com.openai.snapo.demo.shared.tasks.DemoTask
import com.openai.snapo.demo.shared.tasks.TaskList
import com.openai.snapo.demo.shared.tasks.TasksApi
import com.openai.snapo.demo.shared.tasks.TasksApiException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

internal class HttpUrlConnectionTasksApi(
    private val openConnection: (URL) -> HttpURLConnection,
    private val tasksUrl: suspend () -> String,
) : TasksApi {
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun list(): List<DemoTask> = request<TaskList>("GET").tasks

    override suspend fun create(title: String): DemoTask = request(
        "POST",
        json.encodeToString(CreateTask(title)).toByteArray(Charsets.UTF_8),
    )

    @Suppress("ThrowsCount")
    private suspend inline fun <reified T> request(method: String, body: ByteArray? = null): T {
        return try {
            val url = URL(tasksUrl())
            withContext(Dispatchers.IO) {
                val connection = openConnection(url)
                try {
                    connection.requestMethod = method
                    connection.connectTimeout = RequestTimeoutMillis
                    connection.readTimeout = RequestTimeoutMillis
                    if (body != null) {
                        connection.doOutput = true
                        connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                        connection.setFixedLengthStreamingMode(body.size)
                        connection.outputStream.use { it.write(body) }
                    }
                    val status = connection.responseCode
                    if (status !in 200..299) {
                        throw TasksApiException.http(
                            status,
                            "This demo supports inspection only. Use the OkHttp or Ktor demo to test interception.",
                        )
                    }
                    connection.inputStream.bufferedReader(Charsets.UTF_8).use {
                        json.decodeFromString<T>(it.readText())
                    }
                } finally {
                    connection.disconnect()
                }
            }
        } catch (error: SerializationException) {
            throw TasksApiException.invalidResponse(error)
        } catch (error: IOException) {
            throw TasksApiException.transport(error)
        }
    }
}

private const val RequestTimeoutMillis = 30_000

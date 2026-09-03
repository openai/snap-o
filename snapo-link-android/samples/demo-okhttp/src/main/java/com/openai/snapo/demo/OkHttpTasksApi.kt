package com.openai.snapo.demo

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
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.coroutines.executeAsync
import java.io.IOException

internal class OkHttpTasksApi(
    private val client: OkHttpClient,
    private val tasksUrl: suspend () -> String,
) : TasksApi {
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun list(): List<DemoTask> = request<TaskList> {
        Request.Builder().url(tasksUrl()).build()
    }.tasks

    override suspend fun create(title: String): DemoTask = request {
        val body = json.encodeToString(CreateTask(title))
            .toRequestBody("application/json; charset=utf-8".toMediaType())
        Request.Builder().url(tasksUrl()).post(body).build()
    }

    @Suppress("ThrowsCount")
    private suspend inline fun <reified T> request(build: () -> Request): T {
        return try {
            client.newCall(build()).executeAsync().use { response ->
                withContext(Dispatchers.IO) {
                    if (!response.isSuccessful) throw TasksApiException.http(response.code)
                    json.decodeFromString<T>(response.body.string())
                }
            }
        } catch (error: SerializationException) {
            throw TasksApiException.invalidResponse(error)
        } catch (error: IOException) {
            throw TasksApiException.transport(error)
        }
    }
}

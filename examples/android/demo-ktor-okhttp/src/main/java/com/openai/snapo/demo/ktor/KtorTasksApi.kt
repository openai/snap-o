package com.openai.snapo.demo.ktor

import com.openai.snapo.demo.shared.tasks.CreateTask
import com.openai.snapo.demo.shared.tasks.DemoTask
import com.openai.snapo.demo.shared.tasks.TaskList
import com.openai.snapo.demo.shared.tasks.TasksApi
import com.openai.snapo.demo.shared.tasks.TasksApiException
import io.ktor.client.HttpClient
import io.ktor.client.call.NoTransformationFoundException
import io.ktor.client.call.body
import io.ktor.client.plugins.expectSuccess
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.serialization.ContentConvertException
import java.io.IOException

internal class KtorTasksApi(
    private val client: HttpClient,
    private val tasksUrl: suspend () -> String,
) : TasksApi {
    override suspend fun list(): List<DemoTask> = request<TaskList> {
        client.get(tasksUrl()) { expectSuccess = false }
    }.tasks

    override suspend fun create(title: String): DemoTask = request {
        client.post(tasksUrl()) {
            expectSuccess = false
            contentType(ContentType.Application.Json)
            setBody(CreateTask(title))
        }
    }

    @Suppress("ThrowsCount")
    private suspend inline fun <reified T> request(send: () -> HttpResponse): T {
        return try {
            val response = send()
            if (response.status.value !in 200..299) throw TasksApiException.http(response.status.value)
            response.body<T>()
        } catch (error: ContentConvertException) {
            throw TasksApiException.invalidResponse(error)
        } catch (error: NoTransformationFoundException) {
            throw TasksApiException.invalidResponse(error)
        } catch (error: IOException) {
            throw TasksApiException.transport(error)
        }
    }
}

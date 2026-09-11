package com.openai.snapo.demo.shared.tasks

import kotlinx.serialization.Serializable
import java.io.IOException

@Serializable
data class DemoTask(val id: String, val title: String, val status: String)

@Serializable
data class TaskList(val tasks: List<DemoTask>)

@Serializable
data class CreateTask(val title: String)

/** Implementations translate request failures to TasksApiException and preserve coroutine cancellation. */
interface TasksApi {
    suspend fun list(): List<DemoTask>
    suspend fun create(title: String): DemoTask
}

class TasksApiException(override val message: String, cause: Throwable? = null) : Exception(message, cause) {
    companion object {
        fun http(
            statusCode: Int,
            unavailableHint: String = "Use Snap-O interception to supply responses, then tap Refresh.",
        ) = TasksApiException(
            if (statusCode == 404) {
                "The tasks API is not available. $unavailableHint"
            } else {
                "The tasks API returned HTTP $statusCode."
            },
        )

        fun invalidResponse(cause: Throwable) = TasksApiException(
            "The tasks API returned an invalid response. Check the route handler's JSON.",
            cause,
        )

        fun transport(cause: IOException) = TasksApiException(cause.message ?: "The request failed. Try again.", cause)
    }
}

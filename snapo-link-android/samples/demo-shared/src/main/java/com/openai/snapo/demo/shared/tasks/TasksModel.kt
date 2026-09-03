package com.openai.snapo.demo.shared.tasks

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

data class TasksState(
    val tasks: List<DemoTask> = emptyList(),
    val title: String = "",
    val isLoading: Boolean = false,
    val hasLoaded: Boolean = false,
    val error: String? = null,
)

class TasksModel(
    private val api: TasksApi,
    private val scope: CoroutineScope,
    private val savedStateHandle: SavedStateHandle,
) {
    var state by mutableStateOf(TasksState(title = savedStateHandle[TaskTitleKey] ?: ""))
        private set

    fun updateTitle(title: String) {
        savedStateHandle[TaskTitleKey] = title
        state = state.copy(title = title)
    }

    fun refresh() {
        runRequest { loadTasks() }
    }

    fun add() {
        val title = state.title.trim()
        if (title.isEmpty()) return
        runRequest {
            val task = api.create(title)
            updateTitle("")
            state = state.copy(tasks = state.tasks + task, hasLoaded = true)
            loadTasks()
        }
    }

    private suspend fun loadTasks() {
        state = state.copy(tasks = api.list(), hasLoaded = true)
    }

    private fun runRequest(block: suspend () -> Unit) {
        scope.launch {
            if (state.isLoading) return@launch
            state = state.copy(isLoading = true, error = null)
            try {
                block()
            } catch (error: TasksApiException) {
                state = state.copy(error = error.message)
            } finally {
                state = state.copy(isLoading = false)
            }
        }
    }
}

private const val TaskTitleKey = "taskTitle"

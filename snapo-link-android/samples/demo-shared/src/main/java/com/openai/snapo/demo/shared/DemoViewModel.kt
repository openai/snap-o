package com.openai.snapo.demo.shared

import android.util.Log
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.openai.snapo.demo.shared.tasks.TasksModel
import kotlinx.coroutines.launch
import java.io.IOException

class DemoViewModel(private val client: DemoClient, savedStateHandle: SavedStateHandle) : ViewModel(client) {
    val actions: List<DemoAction> = DemoAction.entries.filter { client.handlerFor(it) != null }
    val tasks = TasksModel(client.tasksApi, viewModelScope, savedStateHandle)

    init {
        tasks.refresh()
    }

    fun run(action: DemoAction) {
        val handler = client.handlerFor(action) ?: return
        viewModelScope.launch {
            try {
                handler()
            } catch (error: IOException) {
                Log.e("SnapODemo", "Request failed: ${action.title}", error)
            }
        }
    }

    companion object {
        fun factory(createClient: () -> DemoClient) = viewModelFactory {
            initializer {
                val savedStateHandle = createSavedStateHandle()
                DemoViewModel(createClient(), savedStateHandle)
            }
        }
    }
}

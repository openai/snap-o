package com.openai.snapo.demo.shared

import android.util.Log
import com.openai.snapo.demo.shared.tasks.TasksModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.IOException

class DemoModel(private val client: DemoClient) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val actions: List<DemoAction> = DemoAction.entries.filter { client.handlerFor(it) != null }
    val tasks = TasksModel(client.tasksApi, scope)

    fun run(action: DemoAction) {
        val handler = client.handlerFor(action) ?: return
        scope.launch {
            try {
                handler()
            } catch (error: IOException) {
                Log.e("SnapODemo", "Request failed: ${action.title}", error)
            }
        }
    }

    fun close() {
        scope.cancel()
        client.close()
    }
}

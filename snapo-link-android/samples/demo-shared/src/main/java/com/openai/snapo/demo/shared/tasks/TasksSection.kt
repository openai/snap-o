package com.openai.snapo.demo.shared.tasks

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

private data class TasksState(
    val tasks: List<DemoTask> = emptyList(),
    val isLoading: Boolean = false,
    val hasLoaded: Boolean = false,
    val error: String? = null,
)

@Composable
fun TasksSection(api: TasksApi) {
    val scope = rememberCoroutineScope()
    var state by remember { mutableStateOf(TasksState()) }
    var title by rememberSaveable { mutableStateOf("") }

    suspend fun refresh() {
        state = state.copy(isLoading = true, error = null)
        try {
            state = state.copy(tasks = api.list(), hasLoaded = true)
        } catch (error: TasksApiException) {
            state = state.copy(error = error.message)
        } finally {
            state = state.copy(isLoading = false)
        }
    }

    LaunchedEffect(api) { refresh() }

    TasksContent(
        state = state,
        title = title,
        onTitleChange = { title = it },
        onRefresh = { scope.launch { if (!state.isLoading) refresh() } },
        onAdd = {
            scope.launch {
                if (state.isLoading || title.isBlank()) return@launch
                state = state.copy(isLoading = true, error = null)
                try {
                    val task = api.create(title.trim())
                    title = ""
                    state = state.copy(tasks = state.tasks + task, hasLoaded = true)
                    refresh()
                } catch (error: TasksApiException) {
                    state = state.copy(error = error.message)
                } finally {
                    state = state.copy(isLoading = false)
                }
            }
        },
    )
}

@Composable
private fun TasksContent(
    state: TasksState,
    title: String,
    onTitleChange: (String) -> Unit,
    onRefresh: () -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HorizontalDivider(modifier = Modifier.padding(top = 8.dp))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Tasks", style = MaterialTheme.typography.titleLarge)
            RefreshButton(isLoading = state.isLoading, onClick = onRefresh)
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = title,
                onValueChange = onTitleChange,
                placeholder = { Text("New task") },
                singleLine = true,
                enabled = !state.isLoading,
                shape = MaterialTheme.shapes.extraSmall,
                modifier = Modifier.weight(1f).semantics { contentDescription = "New task" },
            )
            Button(
                onClick = onAdd,
                enabled = !state.isLoading && title.isNotBlank(),
                shape = MaterialTheme.shapes.extraSmall,
                modifier = Modifier.height(56.dp).widthIn(min = 80.dp),
            ) { Text("Add", style = MaterialTheme.typography.bodyLarge) }
        }
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        if (state.hasLoaded && state.tasks.isEmpty() && state.error == null) {
            Text("No tasks yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (state.tasks.isNotEmpty()) {
            Column {
                state.tasks.forEach { task -> TaskRow(task) }
            }
        }
    }
}

@Composable
private fun RefreshButton(isLoading: Boolean, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        enabled = !isLoading,
        modifier = Modifier.semantics {
            if (isLoading) stateDescription = "Loading tasks"
        },
    ) {
        Box(contentAlignment = Alignment.Center) {
            // Keep the label's space so loading does not resize the button.
            Text("Refresh", modifier = Modifier.alpha(if (isLoading) 0f else 1f))
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                )
            }
        }
    }
}

@Composable
private fun TaskRow(task: DemoTask) {
    val isCompleted = task.status == "completed"
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .semantics(mergeDescendants = true) {
                role = Role.Checkbox
                toggleableState = ToggleableState(isCompleted)
                disabled()
            },
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = isCompleted,
            onCheckedChange = null,
            enabled = false,
            modifier = Modifier.size(24.dp),
        )
        Text(task.title, style = MaterialTheme.typography.bodyLarge)
    }
}

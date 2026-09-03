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

@Composable
fun TasksSection(model: TasksModel) {
    val state = model.state
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HorizontalDivider(modifier = Modifier.padding(top = 8.dp))
        Row(
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Tasks", style = MaterialTheme.typography.titleLarge)
            RefreshButton(isLoading = state.isLoading, onClick = model::refresh)
        }
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = state.title,
                onValueChange = model::updateTitle,
                placeholder = { Text("New task") },
                singleLine = true,
                enabled = !state.isLoading,
                shape = MaterialTheme.shapes.extraSmall,
                modifier = Modifier.weight(1f).semantics { contentDescription = "New task" },
            )
            Button(
                onClick = model::add,
                enabled = !state.isLoading && state.title.isNotBlank(),
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
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

@Composable
private fun TaskRow(task: DemoTask) {
    val isCompleted = task.status == "completed"
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .semantics(mergeDescendants = true) {
                role = Role.Checkbox
                toggleableState = ToggleableState(isCompleted)
                disabled()
            },
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

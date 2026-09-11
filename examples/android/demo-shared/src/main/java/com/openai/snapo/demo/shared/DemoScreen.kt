package com.openai.snapo.demo.shared

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.openai.snapo.demo.shared.tasks.DemoTask
import com.openai.snapo.demo.shared.tasks.TasksSection
import com.openai.snapo.demo.shared.tasks.TasksState

@Composable
fun DemoScreen(model: DemoViewModel) {
    DemoScreen(
        actions = model.actions,
        tasks = model.tasks.state,
        onAction = model::run,
        onTitleChange = model.tasks::updateTitle,
        onAdd = model.tasks::add,
        onRefresh = model.tasks::refresh,
    )
}

@Composable
private fun DemoScreen(
    actions: List<DemoAction>,
    tasks: TasksState,
    onAction: (DemoAction) -> Unit,
    onTitleChange: (String) -> Unit,
    onAdd: () -> Unit,
    onRefresh: () -> Unit,
) {
    MaterialTheme {
        Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
            Column(
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.padding(innerPadding).verticalScroll(rememberScrollState()).padding(16.dp),
            ) {
                actions.forEach { action ->
                    Button(onClick = { onAction(action) }) {
                        Text(action.title)
                    }
                }
                TasksSection(
                    state = tasks,
                    onTitleChange = onTitleChange,
                    onAdd = onAdd,
                    onRefresh = onRefresh,
                )
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun DemoPreview() {
    DemoScreen(
        actions = DemoAction.entries,
        tasks = TasksState(
            tasks = listOf(
                DemoTask(id = "1", title = "Try response overrides", status = "pending"),
                DemoTask(id = "2", title = "Inspect a request", status = "completed"),
            ),
            hasLoaded = true,
        ),
        onAction = {},
        onTitleChange = {},
        onAdd = {},
        onRefresh = {},
    )
}

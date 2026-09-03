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
import androidx.compose.ui.unit.dp
import com.openai.snapo.demo.shared.tasks.TasksSection

@Composable
fun DemoScreen(model: DemoModel) {
    MaterialTheme {
        Scaffold(modifier = Modifier.fillMaxSize()) { innerPadding ->
            DemoContent(model = model, modifier = Modifier.padding(innerPadding))
        }
    }
}

@Composable
private fun DemoContent(model: DemoModel, modifier: Modifier = Modifier) {
    Column(
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = modifier.verticalScroll(rememberScrollState()).padding(16.dp),
    ) {
        model.actions.forEach { action ->
            Button(onClick = { model.run(action) }) {
                Text(action.title)
            }
        }
        TasksSection(model.tasks)
    }
}

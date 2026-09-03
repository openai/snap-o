package com.openai.snapo.demo.httpurlconnection

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.tooling.preview.Preview
import com.openai.snapo.demo.shared.DemoModel
import com.openai.snapo.demo.shared.DemoScreen

class MainActivity : ComponentActivity() {
    private val model = DemoModel(HttpUrlConnectionDemoClient())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        model.tasks.updateTitle(savedInstanceState?.getString(TaskTitleKey).orEmpty())
        model.tasks.refresh()
        enableEdgeToEdge()
        setContent { DemoScreen(model) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(TaskTitleKey, model.tasks.state.title)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        model.close()
        super.onDestroy()
    }
}

@Preview(showBackground = true)
@Composable
private fun DemoPreview() {
    val model = remember { DemoModel(HttpUrlConnectionDemoClient()) }
    DisposableEffect(model) {
        onDispose { model.close() }
    }
    DemoScreen(model)
}

private const val TaskTitleKey = "taskTitle"

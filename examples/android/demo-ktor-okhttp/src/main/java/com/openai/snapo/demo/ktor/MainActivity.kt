package com.openai.snapo.demo.ktor

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.openai.snapo.demo.shared.DemoScreen
import com.openai.snapo.demo.shared.DemoViewModel

class MainActivity : ComponentActivity() {
    private val model: DemoViewModel by viewModels { DemoViewModel.factory(::KtorDemoClient) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { DemoScreen(model) }
    }
}

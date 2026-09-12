package com.example.snapo.tool

import android.content.Context
import androidx.startup.Initializer
import com.openai.snapo.tool.ToolServer

class ExampleInitializer : Initializer<ToolServer> {
    override fun create(context: Context): ToolServer = exampleServer().apply {
        startIfAllowed(context)
    }

    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}

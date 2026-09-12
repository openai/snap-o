package com.example.snapo.tool

import android.content.Context
import androidx.startup.Initializer
import com.openai.snapo.plugin.PluginServer

class ExampleInitializer : Initializer<PluginServer> {
    override fun create(context: Context): PluginServer = exampleServer().apply {
        startIfAllowed(context)
    }

    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}

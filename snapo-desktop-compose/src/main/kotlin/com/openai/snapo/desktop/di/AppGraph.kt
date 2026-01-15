package com.openai.snapo.desktop.di

import com.openai.snapo.desktop.inspector.NetworkInspectorStore
import dev.zacsweers.metro.DependencyGraph

@DependencyGraph(AppScope::class)
interface AppGraph {
    val store: NetworkInspectorStore
}

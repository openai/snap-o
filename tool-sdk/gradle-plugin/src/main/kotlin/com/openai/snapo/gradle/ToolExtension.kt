package com.openai.snapo.gradle

import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property

abstract class ToolExtension {
    abstract val id: Property<String>
    abstract val displayName: Property<String>
    abstract val protocolVersion: Property<Int>
    abstract val icon: Property<String>
    abstract val hostApiVersion: Property<Int>
    abstract val frontendDirectory: DirectoryProperty
    abstract val downloadNode: Property<Boolean>
    abstract val nodeVersion: Property<String>

    /** Built frontend files. Set from a task provider to use another build plugin. */
    abstract val frontendAssets: DirectoryProperty
}

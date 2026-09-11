package com.openai.snapo.gradle

import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property

abstract class InspectorExtension {
    abstract val id: Property<String>
    abstract val displayName: Property<String>
    abstract val protocolVersion: Property<Int>
    abstract val icon: Property<String>
    abstract val hostApiVersion: Property<Int>
    abstract val frontendDirectory: DirectoryProperty

    /** Built frontend files. Set from a task provider to use another build tool. */
    abstract val frontendAssets: DirectoryProperty
}

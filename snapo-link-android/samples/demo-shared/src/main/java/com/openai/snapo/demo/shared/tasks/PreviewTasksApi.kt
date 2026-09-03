package com.openai.snapo.demo.shared.tasks

object PreviewTasksApi : TasksApi {
    override suspend fun list(): List<DemoTask> = listOf(
        DemoTask("1", "Buy groceries", "pending"),
        DemoTask("2", "Read a chapter", "completed"),
    )

    override suspend fun create(title: String): DemoTask = DemoTask("preview", title, "pending")
}

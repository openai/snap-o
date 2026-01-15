package com.openai.snapo.desktop.ui.json

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

data class JsonOutlineNode(
    val id: String,
    val path: String,
    val key: String?,
    val value: Value,
) {
    sealed interface Value {
        data class Obj(val children: List<JsonOutlineNode>) : Value
        data class Arr(val children: List<JsonOutlineNode>) : Value
        data class Str(val value: String) : Value
        data class Num(val value: String) : Value
        data class Bool(val value: Boolean) : Value
        data object Null : Value
    }

    val isExpandable: Boolean
        get() = when (value) {
            is Value.Obj -> value.children.isNotEmpty()
            is Value.Arr -> value.children.isNotEmpty()
            else -> false
        }

    fun collectExpandableIds(includeSelf: Boolean): Set<String> = when (value) {
        is Value.Obj -> {
            val childIds = value.children.flatMap { it.collectExpandableIds(includeSelf = true) }
            (if (includeSelf && isExpandable) listOf(id) else emptyList()) + childIds
        }

        is Value.Arr -> {
            val childIds = value.children.flatMap { it.collectExpandableIds(includeSelf = true) }
            (if (includeSelf && isExpandable) listOf(id) else emptyList()) + childIds
        }

        else -> emptyList()
    }.toSet()

    fun collectStringNodeIds(includeSelf: Boolean): Set<String> = when (value) {
        is Value.Str -> if (includeSelf) setOf(id) else emptySet()
        is Value.Obj -> value.children.flatMap { it.collectStringNodeIds(includeSelf = true) }
            .toSet()

        is Value.Arr -> value.children.flatMap { it.collectStringNodeIds(includeSelf = true) }
            .toSet()

        else -> emptySet()
    }

    fun inlineValueDescription(maxLength: Int): String {
        val raw = rawInlineValueDescription()
        return if (raw.length <= maxLength) raw else raw.take(maxLength.coerceAtLeast(0) - 3) + "..."
    }

    private fun rawInlineValueDescription(): String = when (value) {
        is Value.Obj -> {
            val children = value.children
            if (children.isEmpty()) {
                "{ }"
            } else {
                val body = children.joinToString(", ") { it.rawInlineKeyValueDescription() }
                "{ $body }"
            }
        }

        is Value.Arr -> {
            val children = value.children
            if (children.isEmpty()) {
                "[ ]"
            } else {
                val body = children.joinToString(", ") { it.rawInlineValueDescription() }
                "[ $body ]"
            }
        }

        is Value.Str -> "\"${value.value.jsonEscapedSnippet()}\""
        is Value.Num -> value.value
        is Value.Bool -> if (value.value) "true" else "false"
        Value.Null -> "null"
    }

    private fun rawInlineKeyValueDescription(): String {
        val k = key ?: return rawInlineValueDescription()
        val keyDisplay = if (k.startsWith("[")) k else "\"$k\""
        return "$keyDisplay: ${rawInlineValueDescription()}"
    }

    fun toJsonElement(): JsonElement = when (value) {
        is Value.Obj -> JsonObject(
            value.children.associate { child ->
                (child.key ?: "") to child.toJsonElement()
            }
        )

        is Value.Arr -> JsonArray(value.children.map { it.toJsonElement() })
        is Value.Str -> JsonPrimitive(value.value)
        is Value.Num -> JsonPrimitive(value.value)
        is Value.Bool -> JsonPrimitive(value.value)
        Value.Null -> JsonNull
    }

    fun copyValueText(prettyPrinted: Boolean): String? {
        return when (value) {
            is Value.Obj, is Value.Arr -> {
                val json = Json { this.prettyPrint = prettyPrinted }
                json.encodeToString(JsonElement.serializer(), toJsonElement())
            }

            is Value.Str -> value.value
            is Value.Num -> value.value
            is Value.Bool -> if (value.value) "true" else "false"
            Value.Null -> "null"
        }
    }

    companion object {
        fun fromJson(text: String): JsonOutlineNode? {
            val element = runCatching { Json.parseToJsonElement(text) }.getOrNull() ?: return null
            return buildNode(element, key = null, path = "$")
        }

        private fun buildNode(element: JsonElement, key: String?, path: String): JsonOutlineNode {
            val value: Value = when (element) {
                is JsonObject -> {
                    val children = element.entries.map { (k, v) ->
                        val childPath = if (path == "$") "$.$k" else "$path.$k"
                        buildNode(v, key = k, path = childPath)
                    }
                    Value.Obj(children)
                }

                is JsonArray -> {
                    val children = element.mapIndexed { index, child ->
                        val childKey = "[$index]"
                        val childPath = if (path == "$") "\$$childKey" else "$path$childKey"
                        buildNode(child, key = childKey, path = childPath)
                    }
                    Value.Arr(children)
                }

                is JsonPrimitive -> {
                    when {
                        element.isString -> Value.Str(element.content)
                        element.booleanOrNull != null -> Value.Bool(element.booleanOrNull!!)
                        element.longOrNull != null || element.doubleOrNull != null -> {
                            Value.Num(element.content)
                        }
                        element.content == "null" -> Value.Null
                        else -> Value.Str(element.content)
                    }
                }
            }

            return JsonOutlineNode(
                id = path,
                path = path,
                key = key,
                value = value,
            )
        }
    }
}

private fun String.jsonEscapedSnippet(): String =
    this
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\t", "\\t")

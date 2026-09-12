package com.openai.snapo.tweaks.internal

import com.openai.snapo.tweaks.BezierCurve

internal fun parseBezierCurve(value: Map<*, *>): BezierCurve? {
    val keys = listOf("x1", "y1", "x2", "y2")
    if (value.keys != keys.toSet()) return null
    return runCatching {
        val points = keys.map { key ->
            val number = value[key] as? Number ?: return null
            TweakNumbers.parse(number.toString()).toFloat()
        }
        BezierCurve(points[0], points[1], points[2], points[3])
    }.getOrNull()
}

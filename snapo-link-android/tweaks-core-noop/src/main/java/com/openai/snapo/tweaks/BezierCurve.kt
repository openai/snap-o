package com.openai.snapo.tweaks

/** A cubic curve from (0, 0) to (1, 1). All control coordinates stay between 0 and 1. */
data class BezierCurve(val x1: Float, val y1: Float, val x2: Float, val y2: Float) {
    init {
        require(x1.isFinite() && x1 in 0f..1f && x2.isFinite() && x2 in 0f..1f) {
            "Bezier X coordinates must be between 0 and 1."
        }
        require(y1.isFinite() && y1 in 0f..1f && y2.isFinite() && y2 in 0f..1f) {
            "Bezier Y coordinates must be between 0 and 1."
        }
    }
}

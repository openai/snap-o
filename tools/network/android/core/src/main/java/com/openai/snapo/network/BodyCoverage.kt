package com.openai.snapo.network

internal enum class BodyCoverage { Absent, Incomplete, Complete }

internal fun bodyCoverage(available: Boolean, absent: Boolean, complete: Boolean): BodyCoverage = when {
    available -> if (complete) BodyCoverage.Complete else BodyCoverage.Incomplete
    absent -> BodyCoverage.Absent
    else -> BodyCoverage.Incomplete
}

internal fun requestBodyCoverage(available: Boolean, hasBody: Boolean?, truncatedBytes: Long?): BodyCoverage =
    bodyCoverage(available, hasBody == false, truncatedBytes == 0L)

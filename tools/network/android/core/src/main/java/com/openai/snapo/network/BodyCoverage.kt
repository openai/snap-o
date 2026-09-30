package com.openai.snapo.network

internal enum class BodyCoverage { Absent, Incomplete, Complete }

internal fun requestBodyCoverage(
    request: RequestWillBeSent?,
    body: CapturedBody?,
): BodyCoverage = when {
    body != null -> if (request?.bodyTruncatedBytes == 0L) BodyCoverage.Complete else BodyCoverage.Incomplete
    request?.hasBody == false || request?.bodySize == 0L -> BodyCoverage.Absent
    else -> BodyCoverage.Incomplete
}

@Suppress("CyclomaticComplexMethod")
internal fun responseBodyCoverage(
    request: RequestWillBeSent?,
    response: ResponseReceived?,
    end: ResponseFinished?,
    failure: RequestFailed?,
    body: CapturedBody?,
): BodyCoverage = when {
    body != null -> if (end != null && failure == null &&
        (end.bodyTruncatedBytes ?: response?.bodyTruncatedBytes ?: 0) == 0L
    ) {
        BodyCoverage.Complete
    } else {
        BodyCoverage.Incomplete
    }
    failure != null && response == null -> BodyCoverage.Absent
    request?.method.equals("HEAD", true) ||
        response?.code in listOf(204, 304) || end?.bodySize == 0L -> BodyCoverage.Absent
    else -> BodyCoverage.Incomplete
}

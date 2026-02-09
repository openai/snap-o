package com.openai.snapo.desktop.inspector

internal fun responseIsDefinedAsBodyless(
    requestMethod: String?,
    responseStatus: Int?,
    responseContentLength: Long?,
): Boolean {
    if (requestMethod.equals("HEAD", ignoreCase = true)) return true
    val status = responseStatus ?: return false
    if (status in 100..199 || status == 204 || status == 304) return true
    return responseContentLength == 0L
}

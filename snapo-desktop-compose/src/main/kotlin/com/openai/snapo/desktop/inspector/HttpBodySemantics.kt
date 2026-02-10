package com.openai.snapo.desktop.inspector

internal fun responseIsDefinedAsBodyless(
    requestMethod: String?,
    responseStatus: Int?,
    responseContentLength: Long?,
): Boolean {
    if (requestMethod.equals("HEAD", ignoreCase = true)) return true
    val status = responseStatus ?: return false
    if (status in 100..199) return true
    if (status == 204) return true
    if (status == 205) return true
    if (status == 304) return true
    return responseContentLength == 0L
}

package com.openai.snapo.desktop.adb

sealed class AdbException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class ServerUnavailable(message: String, cause: Throwable? = null) : AdbException(message, cause)
    class ProtocolFailure(message: String, cause: Throwable? = null) : AdbException(message, cause)
    class ParseFailure(message: String, cause: Throwable? = null) : AdbException(message, cause)
}
